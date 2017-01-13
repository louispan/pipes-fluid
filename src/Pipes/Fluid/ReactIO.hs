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
  , mergeIO
  , mergeIO'
  ) where

import Control.Applicative
import qualified Control.Concurrent.Async.Lifted.Safe as A
import qualified Control.Concurrent.STM as S
import Control.Lens
import Control.Monad.Base
import Control.Monad.Trans.Class
import Control.Monad.Trans.Control
import Data.Constraint.Forall (Forall)
import qualified Pipes as P
import qualified Pipes.Fluid.Alternative as PFA
import qualified Pipes.Prelude as PP

-- | The applicative instance of this combines multiple Producers reactively
-- ie, yields a value as soon as either or both of the input producers yields a value.
-- This creates two threads each time this combinator is used.
-- Warning: This means that the monadic effects are run in isolation from each other
-- so if the monad is something like (StateT s IO), then the state will alternate
-- between the two input producers, which is most likely not what you want.
newtype ReactIO m a = ReactIO
  { _reactivelyIO :: P.Producer a m ()
  }

makeClassy ''ReactIO
makeWrapped ''ReactIO

instance Monad m => Functor (ReactIO m) where
  fmap f (ReactIO as) = ReactIO $ as P.>-> PP.map f

instance (MonadBaseControl IO m, Forall (A.Pure m)) => Applicative (ReactIO m) where
   pure = ReactIO . P.yield
  -- 'ap' doesn't know about initial values
   fs <*> as = ReactIO $
    P.for (_reactivelyIO $ mergeIO fs as) $ \r ->
        case r of
            Left (f, a) -> P.yield $ f a
            Right (Left (f, Just a)) -> P.yield $ f a
            Right (Right (Just f, a)) -> P.yield $ f a
            -- never got anything from one of the signals, can't do anything yet.
            -- drop the event
            Right (Left (_, Nothing)) -> pure ()
            Right (Right (Nothing, _)) -> pure ()

-- | Reactively combines two producers, given initial values to use when the produce hasn't produced anything yet
-- Combine two signals, and returns a signal that emits
-- @Either bothfired (Either (leftFired, previousRight) (previousLeft, rightFired))@.
-- This creates two threads each time this combinator is used.
-- Warning: This means that the monadic effects are run in isolation from each other
-- so if the monad is something like (StateT s IO), then the state will alternate
-- between the two input producers, which is most likely not what you want.
mergeIO' :: (MonadBaseControl IO m, Forall (A.Pure m)) =>
     Maybe x
  -> Maybe y
  -> ReactIO m x
  -> ReactIO m y
  -> ReactIO m (Either (x, y) (Either (x, Maybe y) (Maybe x, y)))
mergeIO' px py (ReactIO xs) (ReactIO ys) = ReactIO $ do
  ax <- lift $ A.async $ P.next xs
  ay <- lift $ A.async $ P.next ys
  doMergeIO px py ax ay

mergeIO :: (MonadBaseControl IO m, Forall (A.Pure m)) =>
  ReactIO m x
  -> ReactIO m y
  -> ReactIO m (Either (x, y) (Either (x, Maybe y) (Maybe x, y)))
mergeIO = mergeIO' Nothing Nothing

doMergeIO :: (MonadBaseControl IO m, Forall (A.Pure m)) =>
     Maybe x
  -> Maybe y
  -> A.Async (Either () (x, P.Producer x m ()))
  -> A.Async (Either () (y, P.Producer y m ()))
  -> P.Producer (Either (x, y) (Either (x, Maybe y) (Maybe x, y))) m ()
doMergeIO px py ax ay = do
    r <- lift $ liftBase . S.atomically $ PFA.bothOrEither (A.waitSTM ax) (A.waitSTM ay)
    case r of
        -- both @ax@ and @ay@ have ended
        Left (Left _, Left _) -> pure ()
        -- @ax@ ended,                @ay@ still waiting
        Right (Left (Left _)) -> do
            -- wait for @ay@ to return and then only use @ys@
            ry <- lift $ A.wait ay
            case ry of
              Left _ -> pure ()
              Right (y', ys') -> do
                P.yield $ Right (Right (px, y'))
                mapYs ys'
        -- @ax@ still waiting,        @ay@ ended
        Right (Right (Left _)) -> do
            -- wait for @ax@ to retrun and then only use @xs@
            rx <- lift $ A.wait ax
            case rx of
              Left _ -> pure ()
              Right (x', xs') -> do
                P.yield $ Right (Left (x', py))
                mapXs xs'
        -- @ax@ produced something,   @ay@ still waiting
        Right (Left (Right (x, xs'))) -> do
            P.yield $ Right (Left (x, py))
            ax' <- lift $ A.async $ P.next xs'
            doMergeIO (Just x) py ax' ay
        -- @ax@ still waiting,        @ay@ produced something
        Right (Right (Right (y, ys'))) -> do
            P.yield $ Right (Right (px, y))
            ay' <- lift $ A.async $ P.next ys'
            doMergeIO px (Just y) ax ay'
        -- @ax@ produced something,   @ay@ ended
        Left (Right (x, xs'), Left _) -> do
            P.yield $ Right (Left (x, py))
            mapXs xs'
        -- @af@ ended,                @aa@ produced something
        Left (Left _, Right (y, ys')) -> do
            P.yield $ Right (Right (px, y))
            mapYs ys'
        -- both @fs@ and @as@ produced something
        Left (Right (x, xs'), Right (y, ys')) -> do
          P.yield $ Left (x, y)
          ax' <- lift $ A.async $ P.next xs'
          ay' <- lift $ A.async $ P.next ys'
          doMergeIO (Just x) (Just y) ax' ay'
  where
      -- transform remaining @ys@ like fmap
      mapYs ys' = ys' P.>-> PP.map (\y -> Right (Right (px, y)))
      -- transform remaining @xs@ like fmap
      mapXs xs' = xs' P.>-> PP.map (\x -> Right (Left (x, py)))
