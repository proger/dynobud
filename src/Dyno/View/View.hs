{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}

module Dyno.View.View
       ( View(..)
       , J
       , JNone(..), JTuple(..), JTriple(..), JQuad(..)
       , jfill
       , v2d, d2v
       , fmapJ, unzipJ
       , fromDMatrix
       ) where

import GHC.Generics ( Generic, Generic1 )

import Data.Foldable ( Foldable )
import Data.Traversable ( Traversable )
import Data.Proxy ( Proxy(..) )
import Data.Vector ( Vector )
import qualified Data.Vector as V

import qualified Casadi.DMatrix as DMatrix
import qualified Casadi.CMatrix as CM

import Dyno.View.Viewable ( Viewable(..) )
import Dyno.Vectorize ( Vectorize(..) )


import Dyno.View.Unsafe.View

-- some helper types
data JNone a = JNone deriving ( Eq, Generic, Generic1, Show, Functor, Foldable, Traversable )
data JTuple f g a = JTuple (J f a) (J g a) deriving ( Generic, Show )
data JTriple f g h a = JTriple (J f a) (J g a) (J h a) deriving ( Generic, Show )
data JQuad f0 f1 f2 f3 a = JQuad (J f0 a) (J f1 a) (J f2 a) (J f3 a) deriving ( Generic, Show )
instance Vectorize JNone where
instance View JNone where
instance (View f, View g) => View (JTuple f g)
instance (View f, View g, View h) => View (JTriple f g h)
instance (View f0, View f1, View f2, View f3) => View (JQuad f0 f1 f2 f3)

jfill :: forall a f . View f => a -> J f (Vector a)
jfill x = mkJ (V.replicate n x)
  where
    n = size (Proxy :: Proxy f)

fromDMatrix :: (CM.CMatrix a, Viewable a, View f) => J f DMatrix.DMatrix -> J f a
fromDMatrix = mkJ . CM.fromDMatrix . unJ

v2d :: View f => J f (V.Vector Double) -> J f DMatrix.DMatrix
v2d = mkJ . CM.fromDVector . unJ

d2v :: View f => J f DMatrix.DMatrix -> J f (V.Vector Double)
d2v = mkJ . DMatrix.dnonzeros . CM.densify . unJ

fmapJ :: View f => (a -> b) -> J f (Vector a) -> J f (Vector b)
fmapJ f = mkJ . V.map f . unJ

unzipJ :: View f => J f (Vector (a,b)) -> (J f (Vector a), J f (Vector b))
unzipJ v = (mkJ x, mkJ y)
  where
    (x,y) = V.unzip (unJ v)
