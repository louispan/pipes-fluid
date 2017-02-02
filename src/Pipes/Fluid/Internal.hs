{-# OPTIONS_GHC -funbox-strict-fields #-}

module Pipes.Fluid.Internal where

import Control.Applicative

data Merged' a b = FromBoth' !a !b
    | FromLeft' !a
    | FromRight' !b

-- | Used internally by React and ReactIO identifying which side (or both) returned values
bothOrEither :: Alternative f => f a -> f b -> f (Merged' a b)
bothOrEither left right =
  (FromBoth' <$> left <*> right)
  <|>
  (FromLeft' <$> left)
  <|>
  (FromRight' <$> right)
{-# INLINABLE bothOrEither #-}
