{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Pipes.Fluid.React
    ( React(..)
    , merge
    , merge'
    , module Pipes.Fluid.Common
    ) where

import Control.Applicative
import Control.Lens
import Control.Monad.Trans.Class
import qualified Pipes as P
import Pipes.Fluid.Common
import qualified Pipes.Fluid.Internal as PI
import qualified Pipes.Prelude as PP

-- | The applicative instance of this combines multiple Producers reactively
-- ie, yields a value as soon as either or both of the input producers yields a value.
newtype React m a = React
    { reactively :: P.Producer a m ()
    }

makeWrapped ''React

instance Monad m =>
         Functor (React m) where
    fmap f (React as) = React $ as P.>-> PP.map f
    {-# INLINABLE fmap #-}

-- | Reactively combines two producers, given initial values to use when the producer is blocked/failed.
-- This only works for Alternative m where failure means there was no effects, eg. 'Control.Concurrent.STM', or @MonadTrans t => t STM@.
-- Be careful of monad transformers like ExceptT that hides the STM Alternative instance.
instance (Alternative m, Monad m) =>
         Applicative (React m) where
    pure = React . P.yield
    {-# INLINABLE pure #-}

    fs <*> as =
        React $
        P.for (reactively $ merge fs as) $ \r ->
            case r of
                Coupled _ f a -> P.yield $ f a
                -- never got anything from one of the signals, can't do anything yet.
                -- fail/retry/block until we get something from the other signal
                LeftOnly _ _ -> lift empty
                RightOnly _ _-> lift empty
    {-# INLINABLE (<*>) #-}

-- | Reactively combines two producers, given initial values to use when the produce hasn't produced anything yet
-- Combine two signals, and returns a signal that emits
-- @Either bothfired (Either (leftFired, previousRight) (previousLeft, rightFired))@.
-- This only works for Alternative m where failure means there was no effects, eg. 'Control.Concurrent.STM', or @MonadTrans t => t STM@.
-- Be careful of monad transformers ExceptT that hides the STM Alternative instance.
merge' :: (Alternative m, Monad m) =>
  Maybe x
  -> Maybe y
  -> React m x
  -> React m y
  -> React m (Merged x y)
merge' px_ py_ (React xs_) (React ys_) = React $ go px_ py_ xs_ ys_
  where
    go px py xs ys = do
        -- use the Alternative of m, not P.Proxy
        r <- lift $ PI.bothOrEither (P.next xs) (P.next ys)
        case r
            -- both fs and as have ended
              of
            PI.FromBoth' (Left _) (Left _) -> pure ()
            -- @xs@ ended,                @ys@ failed/retry/blocked
            PI.FromLeft' (Left _) -> case px of
                Nothing -> ys P.>-> PP.map (RightOnly OtherDead)
                Just x -> ys P.>-> PP.map (Coupled (FromRight OtherDead) x)
            -- @xs@ failed/retry/blocked, @ys@ ended
            PI.FromRight' (Left _) -> case py of
                Nothing -> xs P.>-> PP.map (LeftOnly OtherDead)
                Just y -> xs P.>-> PP.map (\x -> Coupled (FromLeft OtherDead) x y)
            -- @xs@ produced something,   @ys@ failed/retry/blocked
            PI.FromLeft' (Right (x, xs')) -> do
                case py of
                    Nothing -> P.yield $ LeftOnly OtherLive x
                    Just y -> P.yield $ Coupled (FromLeft OtherLive) x y
                go (Just x) py xs' ys
            -- @xs@ failed/retry/blocked, @ys@ produced something
            PI.FromRight' (Right (y, ys')) -> do
                case px of
                    Nothing -> P.yield $ RightOnly OtherLive y
                    Just x -> P.yield $ Coupled (FromRight OtherLive) x y
                go px (Just y) xs ys'
            -- @xs@ produced something,   @ys@ ended
            PI.FromBoth' (Right (x, xs')) (Left _) ->
                case py of
                    Nothing -> do
                        P.yield $ LeftOnly OtherDead x
                        xs' P.>-> PP.map (LeftOnly OtherDead)
                    Just y -> do
                        P.yield $ Coupled (FromLeft OtherDead) x y
                        xs' P.>-> PP.map (\x' -> Coupled (FromLeft OtherDead) x' y)
            -- @fs@ ended,                @as@ produced something
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
                go (Just x) (Just y) xs' ys'
{-# INLINABLE merge' #-}

-- | A simpler version of merge', with the initial values as Nothing
merge :: (Alternative m, Monad m) => React m x -> React m y -> React m (Merged x y)
merge = merge' Nothing Nothing
{-# INLINABLE merge #-}
