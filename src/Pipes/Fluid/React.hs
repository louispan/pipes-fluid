{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Pipes.Fluid.React
  ( HasReact(..)
  , React(..)
  , bothOrEither
  ) where

import Control.Applicative
import Control.Lens
import Control.Monad.Trans.Class
import qualified Pipes as P
import qualified Pipes.Prelude as PP

-- | The applicative instance of this combines multiple Producers reactively
-- ie, yields a value as soon as either or both of the input producers yields a value.
newtype React m a = React
  { _reactively :: P.Producer a m ()
  }

makeClassyFor "HasReact" "react" [("_reactively", "reactively")] ''React
makeWrapped ''React

instance Monad m => Functor (React m) where
  fmap f (React as) = React $ as P.>-> PP.map f

bothOrEither :: Alternative f => f a -> f b -> f (Either (a, b) (Either a b))
bothOrEither left right =
  (curry Left <$> left <*> right)
  <|>
  (Right . Left <$> left)
  <|>
  (Right . Right <$> right)

-- | Reactively combines two producers, given initial values to use when the producer is blocked/failed.
-- This only works for Alternative m where failure means there was no effects, eg. 'Control.Concurrent.STM', or @MonadTrans t => t STM@.
apReact :: (Alternative m, Monad m) =>
  Maybe (a -> b)
  -> Maybe a
  -> React m (a -> b)
  -> React m a
  -> React m b
apReact pf pa (React fs) (React as) = React $ do
  r <- lift $ bothOrEither nextF nextA -- use the Alternative of m, not P.Proxy
  case r of
    -- both fs and as have ended
    Left (Left _, Left _) -> pure ()
    -- @fs@ ended,                @as@ failed/retry/blocked
    Right (Left (Left _)) ->
      -- check previous fs
      case pf of
        -- We never got a value from fs, so we'll never be able to produce a value
        Nothing -> pure ()
        Just f -> mapAs f as
    -- @fs@ failed/retry/blocked, @as@ ended
    Right (Right (Left _)) ->
      -- check previous as
      case pa of
        -- We never got a value from as, so we'll never be able to produce a value
        Nothing -> pure ()
        Just a -> mapFs a fs
    -- @fs@ produced something,   @as@ failed/retry/blocked
    Right (Left (Right (f, fs'))) ->
      case pa of
        -- never got anything from @as@, can't do anything yet.
        -- fail/retry/block until we get something from @as@
        Nothing -> lift empty
        -- use previous a to emit an @f a@
        Just a -> do
          P.yield $ f a
          reactively $ apReact (Just f) pa (React fs') (React as)
    -- @fs@ failed/retry/blocked, @as@ produced something
    Right (Right (Right (a, as'))) ->
      case pf of
        -- never got anything from @fs@, can't do anything yet.
        -- fail/retry/block until we get something from @fs@
        Nothing -> lift empty
        -- use previous a to emit an @f a@
        Just f -> do
          P.yield $ f a
          reactively $ apReact pf (Just a) (React fs) (React as')
    -- @fs@ produced something,   @as@ ended
    Left (Right (f, fs'), Left _) ->
      case pa of
        -- never got anything from @as@, so we'll never be able to produce a value
        Nothing -> pure ()
        -- use previous a to emit an @f a@
        Just a -> do
          P.yield $ f a
          mapFs a fs'
    -- @fs@ ended,                @as@ produced something
    Left (Left _, Right (a, as')) ->
      case pf of
        -- never got anything from @fs@, so we'll never be able to produce a value
        Nothing -> pure ()
        -- use previous a to emit an @f a@
        Just f -> do
          P.yield $ f a
          mapAs f as'
    -- both @fs@ and @as@ produced something
    Left (Right (f, fs'), Right (a, as')) -> do
          P.yield $ f a
          reactively $ apReact (Just f) (Just a) (React fs') (React as')
 where
  nextF = P.next fs
  nextA = P.next as
  -- transform remaining @as@ like fmap
  mapAs f as' = as' P.>-> PP.map f
  -- transform remaining @fs@ like fmap
  mapFs a fs' = fs' P.>-> PP.map ($ a)

instance (Alternative m, Monad m) => Applicative (React m) where
  pure = React . P.yield
  -- 'ap' doesn't know about initial values
  (<*>) = apReact Nothing Nothing
