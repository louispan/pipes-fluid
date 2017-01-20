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
    ( React(..)
    , merge
    , merge'
    ) where

import Control.Applicative
import Control.Lens
import Control.Monad.Trans.Class
import qualified Pipes as P
import qualified Pipes.Fluid.Alternative as PFA
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

-- | Reactively combines two producers, given initial values to use when the producer is blocked/failed.
-- This only works for Alternative m where failure means there was no effects, eg. 'Control.Concurrent.STM', or @MonadTrans t => t STM@.
-- Be careful of monad transformers like ExceptT that hides the STM Alternative instance.
instance (Alternative m, Monad m) =>
         Applicative (React m) where
    pure = React . P.yield
    fs <*> as =
        React $
        P.for (reactively $ merge fs as) $ \r ->
            case r of
                Left (f, a) -> P.yield $ f a
                Right (Left (f, Just a)) -> P.yield $ f a
                Right (Right (Just f, a)) -> P.yield $ f a
                -- never got anything from one of the signals, can't do anything yet.
                -- fail/retry/block until we get something from the other signal
                Right (Left (_, Nothing)) -> lift empty
                Right (Right (Nothing, _)) -> lift empty

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
  -> React m (Either (x, y) (Either (x, Maybe y) (Maybe x, y)))
merge' px_ py_ (React xs_) (React ys_) = React $ go px_ py_ xs_ ys_
  where
    go px py xs ys = do
        -- use the Alternative of m, not P.Proxy
        r <- lift $ PFA.bothOrEither (P.next xs) (P.next ys)
        case r
            -- both fs and as have ended
              of
            Left (Left _, Left _) -> pure ()
            -- @xs@ ended,                @ys@ failed/retry/blocked
            Right (Left (Left _)) -> ys P.>-> PP.map useRight
            -- @xs@ failed/retry/blocked, @ys@ ended
            Right (Right (Left _)) -> xs P.>-> PP.map useLeft
            -- @xs@ produced something,   @ys@ failed/retry/blocked
            Right (Left (Right (x, xs'))) -> do
                P.yield $ Right (Left (x, py))
                go (Just x) py xs' ys
            -- @xs@ failed/retry/blocked, @ys@ produced something
            Right (Right (Right (y, ys'))) -> do
                P.yield $ useRight y
                go px (Just y) xs ys'
            -- @xs@ produced something,   @ys@ ended
            Left (Right (x, xs'), Left _) -> do
                P.yield $ useLeft x
                xs' P.>-> PP.map useLeft
            -- @fs@ ended,                @as@ produced something
            Left (Left _, Right (y, ys')) -> do
                P.yield $ useRight y
                ys' P.>-> PP.map useRight
            -- both @fs@ and @as@ produced something
            Left (Right (x, xs'), Right (y, ys')) -> do
                P.yield $ Left (x, y)
                go (Just x) (Just y) xs' ys'
      where
        useRight y = Right (Right (px, y))
        useLeft x = Right (Left (x, py))

-- | A simpler version of merge', with the initial values as Nothing
merge :: (Alternative m, Monad m) => React m x -> React m y -> React m (Either (x, y) (Either (x, Maybe y) (Maybe x, y)))
merge = merge' Nothing Nothing
