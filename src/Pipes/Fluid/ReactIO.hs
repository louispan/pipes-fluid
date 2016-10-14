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
{-# LANGUAGE UndecidableInstances #-}

module Pipes.Fluid.ReactIO
  ( HasReactIO(..)
  , ReactIO(..)
  ) where

import qualified Control.Concurrent.Async.Lifted.Safe as A
import qualified Control.Concurrent.STM as S
import Control.Lens
import Control.Monad.Base
import Control.Monad.Trans.Class
import Control.Monad.Trans.Control
import Data.Constraint.Forall (Forall)
import qualified Pipes as P
import qualified Pipes.Fluid.React as PFR
import qualified Pipes.Prelude as PP

-- | The applicative instance of this combines multiple Producers reactively
-- ie, yields a value as soon as either or both of the input producers yields a value.
-- This creates two threads each time this combinator is used.
newtype ReactIO m a = ReactIO
  { _reactivelyIO :: P.Producer a m ()
  }

makeClassyFor "HasReactIO" "reactIO" [("_reactivelyIO", "reactivelyIO")] ''ReactIO
makeWrapped ''ReactIO

instance Monad m => Functor (ReactIO m) where
  fmap f (ReactIO as) = ReactIO $ as P.>-> PP.map f

-- | Reactively combines two producers, given initial values to use when the producer has not yet returned a value.
apReactiveIO :: forall m a b. (MonadBaseControl IO m, Forall (A.Pure m)) =>
     Maybe (a -> b)
  -> Maybe a
  -> ReactIO m (a -> b)
  -> ReactIO m a
  -> ReactIO m b
apReactiveIO pf pa (ReactIO fs) (ReactIO as) = ReactIO $ do
  af <- lift $ A.async $ P.next fs
  aa <- lift $ A.async $ P.next as
  doApReactiveIO pf pa af aa

doApReactiveIO :: forall m a b. (MonadBaseControl IO m, Forall (A.Pure m)) =>
     Maybe (a -> b)
  -> Maybe a
  -> A.Async (Either () (a -> b, P.Producer (a -> b) m ()))
  -> A.Async (Either () (a, P.Producer a m ()))
  -> P.Producer b m ()
doApReactiveIO pf pa af aa = do
  r <- lift $ liftBase . S.atomically $ PFR.bothOrEither (A.waitSTM af) (A.waitSTM aa)
  case r of
  -- both @af@ and @aa@ have ended
    Left (Left _, Left _) -> pure ()
    -- @af@ ended,                @aa@ still waiting
    Right (Left (Left _)) ->
      -- check previous fs
      case pf of
      -- We never got a value from fs, so we'll never be able to produce a value
      Nothing -> pure ()
      -- wait for @aa@ to return and then only use @as@
      Just f -> do
        ra <- lift $ A.wait aa
        case ra of
          Left _ -> pure ()
          Right (a', as') -> do
            P.yield $ f a'
            mapAs f as'
    -- @af@ still waiting,        @aa@ ended
    Right (Right (Left _)) ->
      -- check previous as
      case pa of
        -- We never got a value from as, so we'll never be able to produce a value
        Nothing -> pure ()
        -- wait for @af@ to reutnr and then only use @fs@
        Just a -> do
          rf <- lift $ A.wait af
          case rf of
            Left _ -> pure ()
            Right (f', fs') -> do
              P.yield $ f' a
              mapFs a fs'
    -- @af@ produced something,   @aa@ still waiting
    Right (Left (Right (f, fs'))) -> do
      case pa of
        -- never got anything from @as@, can't do anything yet.
        Nothing -> pure ()
        -- use previous a to emit an @f a@
        Just a -> P.yield $ f a
      af' <- lift $ A.async $ P.next fs'
      doApReactiveIO (Just f) pa af' aa
    -- @af@ still waiting,        @aa@ produced something
    Right (Right (Right (a, as'))) -> do
      case pf of
        -- never got anything from @fs@, can't do anything yet.
        Nothing -> pure ()
        -- use previous a to emit an @f a@
        Just f -> P.yield $ f a
      aa' <- lift $ A.async $ P.next as'
      doApReactiveIO pf (Just a) af aa'
    -- @af@ produced something,   @aa@ ended
    Left (Right (f, fs'), Left _) ->
      case pa of
        -- never got anything from @as@, so we'll never be able to produce a value
        Nothing -> pure ()
        -- use previous a to emit an @f a@
        Just a -> do
          P.yield $ f a
          mapFs a fs'
    -- @af@ ended,                @aa@ produced something
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
      af' <- lift $ A.async $ P.next fs'
      aa' <- lift $ A.async $ P.next as'
      doApReactiveIO (Just f) (Just a) af' aa'
 where
  -- transform remaining @as@ like fmap
  mapAs f as' = as' P.>-> PP.map f
  -- transform remaining @fs@ like fmap
  mapFs a fs' = fs' P.>-> PP.map ($ a)

instance (MonadBaseControl IO m, Forall (A.Pure m)) => Applicative (ReactIO m) where
   pure = ReactIO . P.yield
  -- 'ap' doesn't know about initial values
   (<*>) = apReactiveIO Nothing Nothing
