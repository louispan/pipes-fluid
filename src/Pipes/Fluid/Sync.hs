{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE BangPatterns #-}

module Pipes.Fluid.Sync
    ( Sync(..)
    ) where

import Control.Lens
import Control.Monad
import Control.Monad.Trans.Class
import qualified Pipes as P
import qualified Pipes.Prelude as PP

-- | The applicative instance of this combines multiple Producers synchronously
-- ie, yields a value only when both of the input producers yields a value.
-- Ends as soon as any of the input producer is ended.
newtype Sync m a = Sync
    { synchronously :: P.Producer a m ()
    }

makeWrapped ''Sync

instance Monad m => Functor (Sync m) where
    fmap f (Sync as) = Sync $ as P.>-> PP.map f

instance Monad m => Applicative (Sync m) where
    pure = Sync . forever . P.yield
    Sync xs <*> Sync ys = Sync $ go xs ys

go :: Monad m => P.Producer (t -> a) m r -> P.Producer t m r -> P.Proxy x' x () a m ()
go fs as = do
    rf <- lift $ P.next fs
    ra <- lift $ P.next as
    case (rf, ra) of
        (Left _, _) -> pure ()
        (_, Left _) -> pure ()
        (Right (f, fs'), Right (a, as')) -> do
            P.yield $ f a
            go fs' as'

instance Monad m => Monad (Sync m) where
    Sync as >>= f = Sync $ do
        ra <- lift $ P.next as
        case ra of
            Left _ -> pure ()
            Right (a, as') -> do
                rb <- lift . P.next . synchronously $ f a
                case rb of
                    Left _ -> pure ()
                    Right (b, _) -> do
                        P.yield b
                        synchronously $ Sync as' >>= f
