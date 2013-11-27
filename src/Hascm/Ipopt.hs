{-# OPTIONS_GHC -Wall #-}
{-# Language RankNTypes #-}

module Hascm.Ipopt ( solveNlpIpopt ) where

import qualified Data.Vector as V
import Data.Maybe ( fromMaybe )

import Casadi.Wrappers.Enums ( InputOutputScheme(..) )
import Casadi.Callback
import Casadi.Wrappers.Classes.FX
import Casadi.Wrappers.Classes.OptionsFunctionality
import Casadi.Wrappers.Classes.PrintableObject
import Casadi.Wrappers.Classes.DMatrix
import Casadi.Wrappers.Classes.SXMatrix
import Casadi.Wrappers.Classes.GenericType
import Casadi.Wrappers.Classes.SXFunction ( sxFunction''' )
import Casadi.Wrappers.Classes.SharedObject
import Casadi.Wrappers.Classes.IpoptSolver
import Casadi.Wrappers.Classes.IOInterfaceFX

import Hascm.Vectorize
import Hascm.Casadi.SX
import Hascm.Casadi.IOSchemes

import Hascm.Nlp

inf :: Double
inf = read "Infinity"

toBnds :: V.Vector (Maybe Double, Maybe Double) -> (V.Vector Double, V.Vector Double)
toBnds vs = (V.map (fromMaybe (-inf)) lb, V.map (fromMaybe inf) ub)
  where
    (lb,ub) = V.unzip vs

solveNlpIpopt ::
  forall x p g . (Vectorize x, Vectorize p, Vectorize g) =>
  Nlp x p g -> x Double -> p Double -> Maybe (x Double -> IO Bool)
  -> IO (Either String (NlpOut x g Double))
solveNlpIpopt nlp x0 p0 callback' = do
  (NlpInputs inputsX' inputsP', NlpFun obj g') <- funToSX (nlpFG nlp)
  let inputsX = vectorize inputsX' :: V.Vector SX
      inputsP = vectorize inputsP' :: V.Vector SX
      g = vectorize g' :: V.Vector SX
  inputsXMat <- sxMatrix''''''''''' inputsX
  inputsPMat <- sxMatrix''''''''''' inputsP
  objMat    <- sxMatrix''''''''''' (V.singleton obj)
  gMat      <- sxMatrix''''''''''' g

  inputScheme <- mkSchemeSXMatrix SCHEME_NLPInput [("x", inputsXMat), ("p", inputsPMat)]
  outputScheme <- mkSchemeSXMatrix SCHEME_NLPOutput [("f", objMat), ("g", gMat)]
  f <- sxFunction''' inputScheme outputScheme
  ipopt <- ipoptSolver'' (castFX f)

  -- add callback if user provides it
  case callback' of
    Nothing -> return ()
    Just callback -> do
      let cb fx' = do
            xval <- ioInterfaceFX_output fx' 0 >>= dmatrix_data
            callbackRet <- callback (devectorize xval)
            return $ if callbackRet then 0 else 1
      casadiCallback <- makeCallback cb >>= genericTypeCallback
      optionsFunctionality_setOption ipopt "iteration_callback" casadiCallback

  sharedObject_init ipopt

  let (lbx,ubx) = toBnds (vectorize $ nlpBX nlp)
      (lbg,ubg) = toBnds (vectorize $ nlpBG nlp)
  ioInterfaceFX_setInput''''' ipopt (vectorize x0) "x0"
  ioInterfaceFX_setInput''''' ipopt (vectorize p0) "p"
  ioInterfaceFX_setInput''''' ipopt lbx "lbx"
  ioInterfaceFX_setInput''''' ipopt ubx "ubx"
  ioInterfaceFX_setInput''''' ipopt lbg "lbg"
  ioInterfaceFX_setInput''''' ipopt ubg "ubg"

  fxSolveSafe ipopt

  solveStatus <- fx_getStat ipopt "return_status"  >>= printableObject_getDescription

  fopt <- fmap V.head $ ioInterfaceFX_output'' ipopt "f" >>= dmatrix_data
  xopt <- ioInterfaceFX_output'' ipopt "x" >>= dmatrix_data
  gopt <- ioInterfaceFX_output'' ipopt "g" >>= dmatrix_data
  lamXOpt <- ioInterfaceFX_output'' ipopt "lam_x" >>= dmatrix_data
  lamGOpt <- ioInterfaceFX_output'' ipopt "lam_g" >>= dmatrix_data
  let lambdaOut = Multipliers { lambdaX = devectorize lamXOpt
                              , lambdaG = devectorize lamGOpt
                              }
      nlpOut = NlpOut { fOpt = fopt
                      , xOpt = devectorize xopt
                      , gOpt = devectorize gopt
                      , lambdaOpt = lambdaOut
                      }
  if solveStatus `elem` ["Solve_Succeeded", "Solved_To_Acceptable_Level"]
    then return (Right nlpOut)
    else return (Left solveStatus)
