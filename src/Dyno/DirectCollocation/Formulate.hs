{-# OPTIONS_GHC -Wall #-}
{-# Language ScopedTypeVariables #-}
{-# Language TypeOperators #-}
{-# Language FlexibleContexts #-}

module Dyno.DirectCollocation.Formulate
       ( makeCollNlp
       , mkTaus
       , interpolate
       , makeGuess
       ) where

import Data.Proxy ( Proxy(..) )
import Data.Vector ( Vector )
import qualified Data.Vector as V
import qualified Data.Foldable as F
import qualified Data.Traversable as T
import qualified Data.Packed.Matrix as Mat
import qualified Numeric.LinearAlgebra.Algorithms as LA
import Linear.Matrix hiding ( trace )
import Linear.V

import JacobiRoots ( shiftedLegendreRoots )

import Dyno.Cov
import Dyno.Vectorize
import Dyno.View.View
import Dyno.View.Viewable ( Viewable )
import Dyno.View.Function -- ( (:*:)(..), MXFun, SXFun, toMXFun, toSXFun, callMXFun, callSXFun )
import Dyno.TypeVecs ( Vec )
import qualified Dyno.TypeVecs as TV
import Dyno.LagrangePolynomials ( lagrangeDerivCoeffs , lagrangeXis )
import Dyno.Nlp ( Nlp(..), Bounds )
import Dyno.Ocp ( OcpPhase(..), Dae )
import Dyno.DirectCollocation.Types
import Dyno.Casadi.SX ( SX )
import Dyno.Casadi.MX ( MX, jacobian, solve, mm, trans, d2m )
import Dyno.Casadi.DMatrix ( DMatrix )

--data RorL = Radau | Legendre deriving (Eq, Show)

makeCollNlp ::
  forall x z u p r o c h s sh sc deg n .
  (Dim deg, Dim n, View x, View p, View u, View z,
   View r, View o, View h, View c, View s, View sh, View sc) =>
  OcpPhase x z u p r o c h s sh sc ->
  IO (Nlp (CollTraj x z u p s n deg) JNone (CollOcpConstraints n deg x r c h sh sc) MX)
makeCollNlp ocp = do
  let -- the collocation points
      taus :: Vec deg Double
      taus = mkTaus deg

      deg = reflectDim (Proxy :: Proxy deg)

      -- coefficients for getting xdot by lagrange interpolating polynomials
      cijs :: Vec (TV.Succ deg) (Vec (TV.Succ deg) Double)
      cijs = lagrangeDerivCoeffs (0 TV.<| taus)

  dynFun <- toSXFun "dynamics_fun" (dynamicsFunction (ocpDae ocp))
  pathConFun <- toSXFun "pathConstraints" (pathConFunction (ocpPathC ocp))

  dynStageConFun' <- toMXFun "dynamicsStageCon" (dynStageConstraints cijs taus dynFun)
  dynStageConFun <- expandMXFun dynStageConFun'
  pathStageConFun' <- toMXFun "pathStageCon" (pathStageConstraints pathConFun)
  pathStageConFun <- expandMXFun pathStageConFun'
  stageFun <- toMXFun "stageFunction" (stageFunction dynStageConFun pathStageConFun)

  return $ Nlp { nlpFG = getFg taus ocp stageFun
               , nlpBX = cat (getBx ocp)
               , nlpBG = cat (getBg ocp)
               , nlpX0 = jfill 0
               , nlpP = cat JNone
               }


mkTaus :: Fractional a => Int -> Vec deg a
mkTaus deg = case shiftedLegendreRoots deg of
  Just taus -> TV.mkVec $ V.map (fromRational . toRational) taus
  Nothing -> error "makeTaus: too high degree"

getFg ::
  forall z x u p r o c h s sh sc n deg .
  (Dim deg, Dim n, View x, View z, View u, View p, View r, View o,
   View c, View h, View s, View sc, View sh)
  => Vec deg Double
  -> OcpPhase x z u p r o c h s sh sc
  -> MXFun
      (J (Cov s) :*: J S :*: J p :*: J (JVec deg S) :*: J x :*: J (JVec deg (JTuple x z)) :*: J (JVec deg u) :*: J (Cov s))
      (J (Cov s) :*: J (CollDynConstraint deg r) :*: J (JVec deg o) :*: J (JVec deg h) :*: J x)
  -> (J (CollTraj x z u p s n deg) MX, J JNone MX)
  -> (J S MX, J (CollOcpConstraints n deg x r c h sh sc) MX)
getFg taus ocp stageFun (collTraj, _) = (obj, cat g)
  where
    -- split up the design vars
    ct@(CollTraj tf p0 parm stages' xf) = split collTraj
    --stages = split stages' :: JVec n (CollStage x z u deg) MX
    stages = unJVec (split stages') :: Vec n (J (CollStage x z u deg) MX)
    spstages = fmap split stages :: Vec n (CollStage x z u deg MX)

    obj = objLagrange + objMayer

    objMayer = ocpMayer ocp tf x0 xf p0 pF
    objLagrange = evaluateQuadratures (ocpLagrange ocp) parm spstages outputs' dt taus times

    -- timestep
    dt = tf / fromIntegral n
    n = ctN ct

    -- initial time at each collocation stage
    t0s :: Vec n (J S MX)
    t0s = TV.mkVec' $ take n [dt * fromIntegral k | k <- [(0::Int)..]]

    -- times at each collocation point
    times :: Vec n (Vec deg (J S MX))
    times = fmap (\t0 -> fmap (\tau -> t0 + (realToFrac tau)*dt) taus) t0s

    times' :: Vec n (J (JVec deg S) MX)
    times' = fmap (cat . JVec) times

    -- initial point at each stage
    x0s :: Vec n (J x MX)
    x0s = fmap (\(CollStage x0' _) -> x0') spstages

    -- final point at each stage (for matching constraint)
    xfs :: Vec n (J x MX)
    xfs = TV.tvshiftl x0s xf

    x0 = (\(CollStage x0' _) -> x0') (TV.tvhead spstages)
    g = CollOcpConstraints
        { coStages = cat (CollTrajConstraints (cat (JVec (fmap cat stageConstraints))))
        , coPathC = cat $ JVec hs
        , coBc = ocpBc ocp x0 xf
        , coSbc = (ocpSc ocp) p0 pF
        }

    -- Q
    covInjections :: Vec n (J (Cov s) MX)
    covInjections = fill (mkJ (d2m (unJ (ocpSq ocp))))

    stageConstraints :: Vec n (CollStageConstraints x deg r sh MX)
    stageConstraints = vzipWith3 (\dc -> CollStageConstraints dc)
                       dcs integratorMatchingConstraints covPathConstraints

    covPathConstraints :: Vec n (J sh MX)
    covPathConstraints = TV.tvzipWith (ocpSh ocp) x0s covs

    integratorMatchingConstraints :: Vec n (J x MX) -- THIS SHOULD BE A NONLINEAR FUNCTION
    integratorMatchingConstraints = vzipWith (-) interpolatedXs xfs

    outputs' :: Vec n (Vec deg (J o MX))
    outputs' = fmap (unJVec . split) outputs

    dcs :: Vec n (J (CollDynConstraint deg r) MX)
    outputs :: Vec n (J (JVec deg o) MX)
    hs :: Vec n (J (JVec deg h) MX)
    interpolatedXs :: Vec n (J x MX)
    (covs, dcs, outputs, hs, interpolatedXs) = TV.tvunzip5 blah_
    (pF, blah_) = T.mapAccumL ff p0 $ TV.tvzip3 spstages times' covInjections

    ff :: J (Cov s) MX -> (CollStage x z u deg MX, J (JVec deg S) MX, J (Cov s) MX) ->
          (J (Cov s) MX, (J (Cov s) MX, J (CollDynConstraint deg r) MX, J (JVec deg o) MX, J (JVec deg h) MX, J x MX))
    ff cov0 (CollStage x0' xzus, stageTimes, covInj) = (cov1, (cov0, dc, output, stageHs, interpolatedX'))
      where
        cov1 :*: dc :*: output :*: stageHs :*: interpolatedX' =
          callMXFun stageFun (cov0 :*: dt :*: parm :*: stageTimes :*: x0' :*: xzs :*: us :*: covInj)

        xzs = cat (JVec xzs') :: J (JVec deg (JTuple x z)) MX
        us = cat (JVec us') :: J (JVec deg u) MX
        (xzs', us') = TV.tvunzip $ fmap toTuple $ unJVec (split xzus)
        toTuple xzu = (cat (JTuple x z), u)
          where
            CollPoint x z u = split xzu



getBx :: (Dim n, Dim deg, View x, View z, View u)
         => OcpPhase x z u p r o c h s sh sc
         -> CollTraj x z u p s n deg (Vector Bounds)
getBx ocp = ct
  where
    --ct :: CollTraj x z u p s n deg (Vector Bounds)
    ct = CollTraj tb sb pb (jreplicate (cat cs)) xb

    --cs :: CollStage x z u deg (Vector Bounds)
    cs = CollStage xb (jreplicate (cat cp))

    --cp :: CollPoint x z u (Vector Bounds)
    cp = CollPoint xb zb ub
    xb = ocpXbnd ocp
    ub = ocpUbnd ocp
    zb = ocpZbnd ocp
    pb = ocpPbnd ocp
    tb = ocpTbnd ocp

    sb = ocpSbnd ocp

getBg :: forall x z u p r o c h s sh sc deg n .
  (Dim n, Dim deg, View x, View r, View c, View h, View sh, View sc)
  => OcpPhase x z u p r o c h s sh sc ->
  CollOcpConstraints n deg x r c h sh sc (Vector Bounds)
getBg ocp =
  CollOcpConstraints
  { coStages = cat $ CollTrajConstraints (jreplicate (cat stageCon))
  , coPathC = jreplicate (jreplicate (ocpPathCBnds ocp))
  , coBc = ocpBcBnds ocp
  , coSbc = ocpScBnds ocp
  }
  where
    stageCon :: CollStageConstraints x deg r sh (Vector Bounds)
    stageCon = CollStageConstraints
               (jfill (Just 0, Just 0)) -- dae residual constraint
               (jfill (Just 0, Just 0)) -- continuity constraint
               (ocpShBnds ocp) -- covariance path constraint

evaluateQuadratures ::
  forall x z u p o n deg a .
  (Dim deg, Dim n, View x, View z, View u, Fractional (J S a), Viewable a) =>
  (J x a -> J z a -> J u a -> J p a -> J o a -> J S a -> J S a) ->
  J p a -> Vec n (CollStage x z u deg a) -> Vec n (Vec deg (J o a)) -> J S a ->
  Vec deg Double -> Vec n (Vec deg (J S a)) -> J S a
evaluateQuadratures f p stages outputs dt taus times =
  (dt *) $ V.sum $ TV.unVec $ TV.tvzipWith3 oneStage stages outputs times
  where
    oneStage :: CollStage x z u deg a -> Vec deg (J o a) -> Vec deg (J S a) -> J S a
    oneStage (CollStage _ stage) output stageTimes = qnext
      where
        qdots :: Vec deg (J S a)
        qdots = TV.tvzipWith3 (\(CollPoint x z u) o t -> f x z u p o t) stagelol output stageTimes
        stagelol = (fmap split (unJVec (split stage))) :: Vec deg (CollPoint x z u a)

        qs = cijInvFr !* qdots

        qnext = interpolate taus 0 qs

    cijs' :: Vec (TV.Succ deg) (Vec (TV.Succ deg) Double)
    cijs' = lagrangeDerivCoeffs (0 TV.<| taus)

    cijs :: Vec deg (Vec deg Double)
    cijs = TV.tvtail $ fmap TV.tvtail cijs'

    cijMat :: Mat.Matrix Double
    cijMat = Mat.fromLists $ F.toList $ fmap F.toList cijs

    cijInv' :: Mat.Matrix Double
    cijInv' = LA.inv cijMat

    cijInv :: Vec deg (Vec deg Double)
    cijInv = TV.mkVec' (map TV.mkVec' (Mat.toLists cijInv'))

    cijInvFr :: Vec deg (Vec deg (J S a))
    cijInvFr = fmap (fmap realToFrac) cijInv

dot :: forall x deg a b. (Fractional (J x a), Real b) => Vec deg b -> Vec deg (J x a) -> J x a
dot cks xs = F.sum $ TV.unSeq elemwise
  where
    elemwise :: Vec deg (J x a)
    elemwise = TV.tvzipWith smul cks xs

    smul :: b -> J x a -> J x a
    smul x y = realToFrac x * y


interpolateXDots' :: (Real b, Fractional (J x a)) => Vec deg (Vec deg b) -> Vec deg (J x a) -> Vec deg (J x a)
interpolateXDots' cjks xs = fmap (`dot` xs) cjks

interpolateXDots ::
  (Real b, Dim deg, Fractional (J x a)) =>
  Vec (TV.Succ deg) (Vec (TV.Succ deg) b)
  -> Vec (TV.Succ deg) (J x a)
  -> Vec deg (J x a)
interpolateXDots cjks xs = TV.tvtail $ interpolateXDots' cjks xs


-- return dynamics
dynamicsFunction ::
  forall x z u p r o a . (View x, View z, View u, View r, View o, Viewable a)
  => Dae x z u p r o a
  -> (J S :*: J p :*: J x :*: J (CollPoint x z u)) a
  -> (J r :*: J o) a
dynamicsFunction dae (t :*: parm :*: x' :*: collPoint) =
  r :*: o
  where
    CollPoint x z u = split collPoint
    (r,o) = dae x' x z u parm t

-- return dynamics
pathConFunction ::
  forall x z u p o h a . (View x, View z, View u, View o, View h, Viewable a)
  => (J x a -> J z a -> J u a -> J p a -> J o a -> J S a -> J h a)
  -> (J S :*: J p :*: J o :*: J (CollPoint x z u)) a
  -> J h a
pathConFunction pathC (t :*: parm :*: o :*: collPoint) =
  pathC x z u parm o t
  where
    CollPoint x z u = split collPoint


-- return dynamics constraints, outputs, and interpolated state
dynStageConstraints ::
  forall x z u p r o deg . (Dim deg, View x, View z, View u, View p, View r, View o)
  => Vec (TV.Succ deg) (Vec (TV.Succ deg) Double) -> Vec deg Double
  -> SXFun (J S :*: J p :*: J x :*: J (CollPoint x z u))
           (J r :*: J o)
  -> (J S :*: J p :*: J (JVec deg S) :*: J (CollStage x z u deg)) MX
  -> (J (CollDynConstraint deg r) :*: J (JVec deg o) :*: J x) MX
dynStageConstraints cijs taus dynFun ((UnsafeJ h) :*: p :*: stageTimes' :*: collStage) =
  (cat (CollDynConstraint (cat (JVec dynConstrs))) :*: cat (JVec outputs) :*: xnext)
  where
    -- interpolated final state
    xnext :: J x MX
    xnext = interpolate taus x0 xs

    stageTimes = unJVec $ split stageTimes'
    CollStage x0 cps' = split collStage

    -- dae constraints (dynamics)
    dynConstrs :: Vec deg (J r MX)
    outputs :: Vec deg (J o MX)
    (dynConstrs, outputs) = TV.tvunzip $ TV.tvzipWith3 applyDae xdots cps stageTimes

    applyDae :: J x MX -> CollPoint x z u MX -> J S MX -> (J r MX, J o MX)
    applyDae x' (CollPoint x z u) t = (r, o)
      where
        r :*: o = callSXFun dynFun (t :*: p :*: x' :*: collPoint)
        collPoint = cat (CollPoint x z u)

    -- state derivatives, maybe these could be useful as outputs
    xdots :: Vec deg (J x MX)
    xdots = fmap (/(UnsafeJ h)) $ interpolateXDots cijs (x0 TV.<| xs)

    xs :: Vec deg (J x MX)
    xs = fmap getX cps

    cps = fmap split (unJVec (split cps')) :: Vec deg (CollPoint x z u MX)


-- return dynamics constraints, outputs, and interpolated state
pathStageConstraints ::
  forall x z u p o h deg . (Dim deg, View x, View z, View u, View p, View o, View h)
  => SXFun (J S :*: J p :*: J o :*: J (CollPoint x z u))
           (J h)
  -> (J p :*: J (JVec deg S) :*: J (JVec deg o) :*: J (JVec deg (CollPoint x z u))) MX
  -> J (JVec deg h) MX
pathStageConstraints pathCFun
  (p :*: stageTimes' :*: outputs :*: collPoints) =
  cat (JVec hs)
  where
    stageTimes = unJVec $ split stageTimes'
    cps = fmap split (unJVec (split collPoints)) :: Vec deg (CollPoint x z u MX)

    -- dae constraints (dynamics)
    hs :: Vec deg (J h MX)
    hs = TV.tvzipWith3 applyH cps stageTimes (unJVec (split outputs))

    applyH :: CollPoint x z u MX -> J S MX -> J o MX -> J h MX
    applyH (CollPoint x z u) t o = pathc'
      where
        pathc' = callSXFun pathCFun (t :*: p :*: o :*: collPoint)
        collPoint = cat (CollPoint x z u)


stageFunction ::
  forall x z u p o s r h deg . (Dim deg, View x, View z, View u, View p, View r, View o, View h, View s)
  => SXFun (J S :*: J p :*: J (JVec deg S) :*: J (CollStage x z u deg))
           (J (CollDynConstraint deg r) :*: J (JVec deg o) :*: J x)
  -> SXFun (J p :*: J (JVec deg S) :*: J (JVec deg o) :*: J (JVec deg (CollPoint x z u)))
           (J (JVec deg h))
  -> (J (Cov s) :*: J S :*: J p :*: J (JVec deg S) :*: J x :*: J (JVec deg (JTuple x z)) :*: J (JVec deg u) :*: J (Cov s)) MX
  -> (J (Cov s) :*: J (CollDynConstraint deg r) :*: J (JVec deg o) :*: J (JVec deg h) :*: J x) MX
stageFunction dynStageFun pathConStageFun (p0' :*: dt :*: parm :*: stageTimes :*: x0' :*: xzs' :*: us :*: q0') =
    (p1 :*: dynConstrs' :*: outputs :*: hs :*: interpolatedX)
  where
    collStage :: CollStage x z u deg MX
    collStage = CollStage x0' collPoints

    collPoints = cat $ JVec $ TV.tvzipWith catXzu (unJVec (split xzs')) (unJVec (split us))

    catXzu :: J (JTuple x z) MX -> J u MX -> J (CollPoint x z u) MX
    catXzu xz u = cat $ CollPoint x z u
      where
        JTuple x z = split xz

    dynConstrs' :: J (CollDynConstraint deg r) MX
    outputs :: J (JVec deg o) MX
    interpolatedX :: J x MX
    dynConstrs' :*: outputs :*: interpolatedX =
      callSXFun dynStageFun (dt :*: parm :*: stageTimes :*: (cat collStage))

    hs :: J (JVec deg h) MX
    hs =
      callSXFun pathConStageFun (parm :*: stageTimes :*: outputs :*: collPoints)
    q0 = toMatrix' q0'
    p0 = toMatrix' p0'

    CollDynConstraint dynConstrs = split dynConstrs'

    f = unJ (dynConstrs :: J (JVec deg r) MX)

    df_dx0 = jacobian f (unJ x0')
    df_dxz = jacobian f (unJ xzs')
    dxz_dx0 = - (solve df_dxz df_dx0) :: MX

    g' = unJ interpolatedX
    dg_dx0 = jacobian g' (unJ x0')
    dg_dxz = jacobian g' (unJ xzs')
    dx1_dx0 = dg_dx0 + mm dg_dxz dxz_dx0

    p1' :: MX
    p1' = dx1_dx0 `mm` p0 `mm` (trans dx1_dx0) + q0

    -- supress casadi zero size matrix error
    p1 :: J (Cov s) MX
    p1 = if size (Proxy :: Proxy s) == 0 then p0' else fromMatrix' p1'



interpolate :: (Dim deg, Real b, Fractional b, Fractional (J x a), View x) =>
               Vec deg b -> J x a -> Vec deg (J x a) -> J x a
interpolate taus x0 xs = dot (TV.mkVec' xis) (x0 TV.<| xs)
  where
    xis = map (lagrangeXis (0 : F.toList taus) 1) [0..deg]
    deg = TV.tvlength taus


-- | make an initial guess
makeGuess ::
  forall x z u p s deg n .
  (Dim n, Dim deg, View x, View z, View u)
  => Double -> (Double -> J x DMatrix) -> (Double -> J z DMatrix) -> (Double -> J u DMatrix)
  -> J (Cov s) DMatrix -> J p DMatrix
  -> CollTraj x z u p s n deg DMatrix -- (Vector Double)
makeGuess tf guessX guessZ guessU cov' parm =
  CollTraj (mkJ (realToFrac tf)) cov' parm guesses (guessX tf)
  where
    -- timestep
    dt = tf / fromIntegral n
    n = vlength (undefined :: Vec n ())

    -- initial time at each collocation stage
    t0s :: Vec n Double
    t0s = TV.mkVec' $ take n [dt * fromIntegral k | k <- [(0::Int)..]]

    -- times at each collocation point
    times :: Vec n (Double, Vec deg Double)
    times = fmap (\t0 -> (t0, fmap (\tau -> t0 + tau*dt) taus)) t0s

    mkGuess' :: (Double, Vec deg Double) -> CollStage x z u deg DMatrix
    mkGuess' (t,ts) = CollStage (guessX t) $
                      cat $ JVec $ fmap (\t' -> cat (CollPoint (guessX t') (guessZ t') (guessU t'))) ts

    guesses :: J (JVec n (CollStage x z u deg)) DMatrix
    guesses = cat $ JVec $ fmap (cat . mkGuess') times

    -- the collocation points
    taus :: Vec deg Double
    taus = mkTaus deg

    deg = vlength (undefined :: Vec deg ())