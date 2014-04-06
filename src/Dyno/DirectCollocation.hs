{-# OPTIONS_GHC -Wall #-}
{-# Language ScopedTypeVariables #-}

module Dyno.DirectCollocation
       ( CollTraj(..)
       , makeCollNlp
       , solveOcp
       ) where

import Data.Proxy
import Data.Vector ( Vector )

import Dyno.View ( View, J, jfill )
import Dyno.Vectorize ( Vectorize )
import Dyno.Ocp ( OcpPhase )
import Dyno.NlpSolver ( NLPSolverClass, NlpSolverStuff, solveNlp' )
import Dyno.Nlp ( Nlp'(..) )
import Dyno.DirectCollocation.Formulate ( makeCollNlp )
import Dyno.DirectCollocation.Types ( CollTraj(..) )
import Dyno.DirectCollocation.Dynamic ( DynCollTraj, ctToDynamic )
import qualified Dyno.TypeVecs as TV

solveOcp ::
  forall x z u p r o c h s sh sc nlp .
  (NLPSolverClass nlp, Vectorize x, Vectorize z, Vectorize u, Vectorize p,
   Vectorize r, Vectorize o, Vectorize c, Vectorize h, View s, View sc, View sh)
  => NlpSolverStuff nlp -> Int -> Int -> Maybe (DynCollTraj (Vector Double) -> IO Bool) -> OcpPhase x z u p r o c h s sh sc -> IO ()
solveOcp solverStuff n deg cb ocp =
  TV.reifyDim n $ \(Proxy :: Proxy n) ->
  TV.reifyDim deg $ \(Proxy :: Proxy deg) -> do
    let guess :: J (CollTraj x z u p s n deg) (Vector Double)
        guess = jfill 1
    nlp <- makeCollNlp ocp
    _ <- solveNlp' solverStuff (nlp {nlpX0' = guess}) (fmap (. ctToDynamic) cb)
    return ()
