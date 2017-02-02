{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Pipes.Fluid.ReactIO
    ( ReactIO(..)
    , mergeIO
    , mergeIO'
    , module Pipes.Fluid.Common
    ) where

import qualified Control.Concurrent.Async.Lifted.Safe as A
import qualified Control.Concurrent.STM as S
import Control.Lens
import Control.Monad.Base
import Control.Monad.Trans.Class
import Control.Monad.Trans.Control
import Data.Constraint.Forall (Forall)
import qualified Pipes as P
import Pipes.Fluid.Common
import qualified Pipes.Fluid.Internal as PI
import qualified Pipes.Prelude as PP

-- | The applicative instance of this combines multiple Producers reactively
-- ie, yields a value as soon as either or both of the input producers yields a value.
-- This creates two threads each time this combinator is used.
-- Warning: This means that the monadic effects are run in isolation from each other
-- so if the monad is something like (StateT s IO), then the state will alternate
-- between the two input producers, which is most likely not what you want.
newtype ReactIO m a = ReactIO
    { reactivelyIO :: P.Producer a m ()
    }

makeWrapped ''ReactIO

instance Monad m => Functor (ReactIO m) where
  fmap f (ReactIO as) = ReactIO $ as P.>-> PP.map f
  {-# INLINABLE fmap #-}

instance (MonadBaseControl IO m, Forall (A.Pure m)) => Applicative (ReactIO m) where
    pure = ReactIO . P.yield
    {-# INLINABLE pure #-}

    -- 'ap' doesn't know about initial values
    fs <*> as = ReactIO $ P.for (reactivelyIO $ mergeIO fs as) $ \r ->
        case r of
            Coupled _ f a -> P.yield $ f a
            -- never got anything from one of the signals, can't do anything yet.
            -- drop the event
            LeftOnly _ _ -> pure ()
            RightOnly _ _-> pure ()
    {-# INLINABLE (<*>) #-}

-- | Reactively combines two producers, given initial values to use when the produce hasn't produced anything yet
-- Combine two signals, and returns a signal that emits
-- @Either bothfired (Either (leftFired, previousRight) (previousLeft, rightFired))@.
-- This creates two threads each time this combinator is used.
-- Warning: This means that the monadic effects are run in isolation from each other
-- so if the monad is something like (StateT s IO), then the state will alternate
-- between the two input producers, which is most likely not what you want.
-- This will be detect as a compile error due to use of Control.Concurrent.Async.Lifted.Safe
mergeIO' :: (MonadBaseControl IO m, Forall (A.Pure m)) =>
     Maybe x
  -> Maybe y
  -> ReactIO m x
  -> ReactIO m y
  -> ReactIO m (Merged x y)
mergeIO' px_ py_ (ReactIO xs_) (ReactIO ys_) = ReactIO $ do
    ax <- lift $ A.async $ P.next xs_
    ay <- lift $ A.async $ P.next ys_
    doMergeIO px_ py_ ax ay
  where
    doMergeIO :: (MonadBaseControl IO m, Forall (A.Pure m)) =>
         Maybe x
      -> Maybe y
      -> A.Async (Either () (x, P.Producer x m ()))
      -> A.Async (Either () (y, P.Producer y m ()))
      -> P.Producer (Merged x y) m ()
    doMergeIO px py ax ay = do
        r <-
            lift $
            liftBase . S.atomically $ PI.bothOrEither (A.waitSTM ax) (A.waitSTM ay)
        case r of
            -- both @ax@ and @ay@ have ended
            PI.FromBoth' (Left _) (Left _) -> pure ()
            -- @ax@ ended,                @ay@ still waiting
            PI.FromLeft' (Left _) -> do
                ry <- lift $ A.wait ay -- wait for @ay@ to return and then
                                       -- only use @ys@
                case ry of
                    Left _ -> pure ()
                    Right (y, ys') -> case px of
                        Nothing -> do
                            P.yield $ RightOnly OtherDead y
                            ys' P.>-> PP.map (RightOnly OtherDead)
                        Just x -> do
                            P.yield $ Coupled (FromRight OtherDead) x y
                            ys' P.>-> PP.map (Coupled (FromRight OtherDead) x)
            -- @ax@ still waiting,        @ay@ ended
            PI.FromRight' (Left _) -> do
                rx <- lift $ A.wait ax -- wait for @ax@ to retrun and then
                                       -- only use @xs@
                case rx of
                    Left _ -> pure ()
                    Right (x, xs') -> case py of
                        Nothing -> do
                            P.yield $ LeftOnly OtherDead x
                            xs' P.>-> PP.map (LeftOnly OtherDead)
                        Just y -> do
                            P.yield $ Coupled (FromLeft OtherDead) x y
                            xs' P.>-> PP.map (\x' -> Coupled (FromLeft OtherDead) x' y)
            -- @ax@ produced something,   @ay@ still waiting
            PI.FromLeft' (Right (x, xs')) -> do
                case py of
                    Nothing -> P.yield $ LeftOnly OtherLive x
                    Just y -> P.yield $ Coupled (FromLeft OtherLive) x y
                ax' <- lift $ A.async $ P.next xs'
                doMergeIO (Just x) py ax' ay
            -- @ax@ still waiting,        @ay@ produced something
            PI.FromRight' (Right (y, ys')) -> do
                case px of
                    Nothing -> P.yield $ RightOnly OtherLive y
                    Just x -> P.yield $ Coupled (FromRight OtherLive) x y
                ay' <- lift $ A.async $ P.next ys'
                doMergeIO px (Just y) ax ay'
            -- @ax@ produced something,   @ay@ ended
            PI.FromBoth' (Right (x, xs')) (Left _) ->
                case py of
                    Nothing -> do
                        P.yield $ LeftOnly OtherDead x
                        xs' P.>-> PP.map (LeftOnly OtherDead)
                    Just y -> do
                        P.yield $ Coupled (FromLeft OtherDead) x y
                        xs' P.>-> PP.map (\x' -> Coupled (FromLeft OtherDead) x' y)
            -- @af@ ended,                @aa@ produced something
            PI.FromBoth' (Left _) (Right (y, ys')) ->
                case px of
                    Nothing -> do
                        P.yield $ RightOnly OtherDead y
                        ys' P.>-> PP.map (RightOnly OtherDead)
                    Just x -> do
                        P.yield $ Coupled (FromRight OtherDead) x y
                        ys' P.>-> PP.map (Coupled (FromRight OtherDead) x)
            -- both @fs@ and @as@ produced something
            PI.FromBoth' (Right (x, xs')) (Right (y, ys')) -> do
                P.yield $ Coupled FromBoth x y
                ax' <- lift $ A.async $ P.next xs'
                ay' <- lift $ A.async $ P.next ys'
                doMergeIO (Just x) (Just y) ax' ay'
      where
        useRight b y = Right (Right (b, px, y))
        useLeft b x = Right (Left (b, x, py))
{-# INLINABLE mergeIO' #-}

mergeIO :: (MonadBaseControl IO m, Forall (A.Pure m))
    => ReactIO m x
    -> ReactIO m y
    -> ReactIO m (Merged x y)
mergeIO = mergeIO' Nothing Nothing
{-# INLINABLE mergeIO #-}
