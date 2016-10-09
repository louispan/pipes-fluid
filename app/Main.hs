{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MonomorphismRestriction #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import Control.Applicative
import Control.Concurrent
import qualified Control.Concurrent.Async.Lifted.Safe as A
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Morph
import Control.Monad.Trans.Control
import Control.Monad.Trans.Identity
import Data.Constraint.Forall (Forall)
import qualified Pipes as P
import qualified Pipes.Fluid.React as PF
import qualified Pipes.Fluid.ReactIO as PF
import qualified Pipes.Fluid.Sync as PF

sig1 :: Monad m => P.Producer Int m ()
sig1 = do
  P.yield 1
  P.yield 2
  P.yield 3
  P.yield 4
  P.yield 5
  P.yield 6
  P.yield 7
  P.yield 8
  P.yield 9

sig2 :: Monad m => P.Producer Int m ()
sig2 = do
  P.yield 20
  P.yield 30
  P.yield 40
  P.yield 50
  P.yield 60

stmSig :: TMVar Int -> P.Producer Int STM ()
stmSig v = forever $ do
  a <- lift $ takeTMVar v
  P.yield a

sigFeeder :: TMVar Int -> Int -> P.Consumer Int IO ()
sigFeeder v i = forever $ do
  lift $ threadDelay i
  a <- P.await
  lift $ atomically $ putTMVar v a

syncSig :: P.Producer Int STM () -> P.Producer Int STM () -> PF.Sync STM (Int, Int, Int)
syncSig as bs = do
  a <- PF.Sync as
  b <- PF.Sync bs
  pure (a, b, a + b)

reactSig' :: (Alternative m, Monad m, Num a) =>
  P.Producer a m ()
  -> P.Producer a m ()
  -> PF.React m (a, a, a)
reactSig' as bs = (\a b -> (a, b, a + b)) <$> PF.React as <*> PF.React bs

reactIOSig' :: (MonadBaseControl IO m, Forall (A.Pure m), Num a) =>
  P.Producer a m ()
  -> P.Producer a m ()
  -> PF.ReactIO m (a, a, a)
reactIOSig' as bs = (\a b -> (a, b, a + b)) <$> PF.ReactIO as <*> PF.ReactIO bs

reactSTMSig :: P.Producer Int STM () -> P.Producer Int STM () -> PF.React STM (Int, Int, Int)
reactSTMSig = reactSig'

reactIdentityTSTMSig ::
  P.Producer Int (IdentityT STM) ()
  -> P.Producer Int (IdentityT STM) ()
  -> PF.React (IdentityT STM) (Int, Int, Int)
reactIdentityTSTMSig = reactSig'

reactIdentityTIOSig :: P.Producer Int  (IdentityT IO) ()
  -> P.Producer Int (IdentityT IO) ()
  -> PF.ReactIO (IdentityT IO) (Int, Int, Int)
reactIdentityTIOSig = reactIOSig'

reactIOSig :: P.Producer Int IO () -> P.Producer Int IO () -> PF.ReactIO IO (Int, Int, Int)
reactIOSig = reactIOSig'

handleBlockedIndefinitely :: BlockedIndefinitelyOnSTM -> IO ()
handleBlockedIndefinitely = const $ pure ()

catchBlockedIndefinitely :: IO () -> IO ()
catchBlockedIndefinitely a = catch a handleBlockedIndefinitely

testSig :: (P.Producer Int STM () -> P.Producer Int STM () -> IO ()) -> IO ()
testSig f = do
  a <- newEmptyTMVarIO
  b <- newEmptyTMVarIO
  let stmSig1 = stmSig a
      stmSig2 = stmSig b
  x <- forkIO $ P.runEffect $ sig1 P.>-> sigFeeder a 300000
  y <- forkIO $ P.runEffect $ sig2 P.>-> sigFeeder b 500000
  catchBlockedIndefinitely $ f stmSig1 stmSig2
  killThread x
  killThread y

sigConsumer :: Show a => P.Consumer a IO ()
sigConsumer = forever $ do
  a <- P.await
  lift $ print a

testSync :: IO ()
testSync = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nSync: only yield a value when both producers yields a value"
  P.runEffect $ hoist atomically (PF.synchronously $ syncSig stmSig1 stmSig2) P.>-> sigConsumer

testReactSTM :: IO ()
testReactSTM = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact STM: yield a value whenever any producer yields a value"
  P.runEffect $ hoist atomically (PF.reactively $ reactSTMSig stmSig1 stmSig2) P.>-> sigConsumer

testReactIdentityTSTM :: IO ()
testReactIdentityTSTM = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact IdentityT STM: reactively yields under 't STM'"
  runIdentityT $ P.runEffect $ hoist (hoist atomically) (PF.reactively $
                                   reactIdentityTSTMSig
                                   (P.hoist lift stmSig1) -- make original producer under IdentityT
                                   (P.hoist lift stmSig2) -- make original producer under IdentityT
                                 )
    P.>-> P.hoist lift sigConsumer -- make original consumer under IdentityT

testReactIO :: IO ()
testReactIO = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact IO: reactively yield under IO using lifted-async."
  P.runEffect $ PF.reactivelyIO (reactIOSig
                                 (hoist atomically stmSig1)
                                 (hoist atomically stmSig2)
                                )
    P.>-> sigConsumer

testReactIdentityTIO :: IO ()
testReactIdentityTIO = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact IdentityT IO: reactively yield under 't IO' using lifted-async."
  runIdentityT $ P.runEffect $ PF.reactivelyIO (reactIdentityTIOSig
                                                (hoist (lift . atomically) stmSig1)
                                                (hoist (lift . atomically) stmSig2)
                                               )
    P.>-> hoist lift sigConsumer

main :: IO ()
main = do
  testSync
  testReactSTM
  testReactIdentityTSTM
  testReactIO
  testReactIdentityTIO
