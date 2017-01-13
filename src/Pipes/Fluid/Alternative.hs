module Pipes.Fluid.Alternative where

import Control.Applicative

bothOrEither :: Alternative f => f a -> f b -> f (Either (a, b) (Either a b))
bothOrEither left right =
  (curry Left <$> left <*> right)
  <|>
  (Right . Left <$> left)
  <|>
  (Right . Right <$> right)
