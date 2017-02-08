module Pipes.Fluid.Util where

import qualified Pipes as P
import Pipes.Fluid.Merge

mergeDiscrete :: (Semigroup x, Monad m) => f x -> f x -> f x
mergeDiscrete xs ys = discrete <$> PF.Impulse xs `merge'` PF.Impulse ys
