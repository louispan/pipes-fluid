{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
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
import Control.Monad.State.Strict
import Data.Constraint.Forall (Forall)
import qualified Pipes as P
import qualified Pipes.Lift as PL
import qualified Pipes.Fluid.React as PF
import qualified Pipes.Fluid.ReactIO as PF
import qualified Pipes.Fluid.Sync as PF
import qualified Pipes.Misc as PM
import Control.Lens
import qualified Pipes.Internal as PI

data Model = Model
    { modelCounter1 :: Int
    , modelCounter2 :: Int
    } deriving (Eq, Show)

makeFields ''Model

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
  P.yield 10
  P.yield 20
  P.yield 30
  P.yield 40
  P.yield 50
  P.yield 60
  P.yield 70

stmSig :: TMVar Int -> P.Producer Int STM ()
stmSig v = forever $ do
  a <- lift $ takeTMVar v
  P.yield a

sigFeeder :: TMVar Int -> Int -> P.Consumer Int IO ()
sigFeeder v i = forever $ do
  lift $ threadDelay i
  a <- P.await
  lift $ atomically $ putTMVar v a

syncAdd :: P.Producer Int STM () -> P.Producer Int STM () -> PF.Sync STM (Int, Int, Int)
syncAdd as bs = do
  a <- PF.Sync as
  b <- PF.Sync bs
  pure (a, b, a + b)

reactAdd :: (Alternative m, Monad m, Num a) =>
  P.Producer a m ()
  -> P.Producer a m ()
  -> PF.React m (a, a, a)
reactAdd as bs = (\a b -> (a, b, a + b)) <$> PF.React as <*> PF.React bs

reactIOAdd :: (MonadBaseControl IO m, Forall (A.Pure m), Num a) =>
  P.Producer a m ()
  -> P.Producer a m ()
  -> PF.ReactIO m (a, a, a)
reactIOAdd as bs = (\a b -> (a, b, a + b)) <$> PF.ReactIO as <*> PF.ReactIO bs

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

sigConsumer :: (MonadIO io, Show a) => P.Consumer a io ()
sigConsumer = forever $ do
  a <- P.await
  liftIO $ print a

testSync :: IO ()
testSync = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nSync: only yield a value when both producers yields a value"
  P.runEffect $ PI.unsafeHoist atomically (PF._synchronously $ syncAdd stmSig1 stmSig2) P.>-> sigConsumer

testReactSTM :: IO ()
testReactSTM = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact STM: yield a value whenever any producer yields a value"
  P.runEffect $ PI.unsafeHoist atomically (PF._reactively $ reactAdd stmSig1 stmSig2) P.>-> sigConsumer

testReactIdentityTSTM :: IO ()
testReactIdentityTSTM = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact IdentityT STM: reactively yields under 't STM'"
  runIdentityT $ P.runEffect $ hoist (hoist atomically) (PF._reactively $
                                   reactAdd
                                   (PI.unsafeHoist lift stmSig1) -- make original producer under IdentityT
                                   (PI.unsafeHoist lift stmSig2) -- make original producer under IdentityT
                                 )
    P.>-> PI.unsafeHoist lift sigConsumer -- make original consumer under IdentityT

testReactStateTSTM :: IO ()
testReactStateTSTM = testSig $ \stmSig1 stmSig2 -> do
   putStrLn "\nReact StateT STM: reactively yields under 'StateT STM'"
   (`evalStateT` (Model 0 0)) $ P.runEffect $ PI.unsafeHoist (hoist atomically) (PF._reactively $
                                 reactAdd
                                    -- make original producer under StateT
                                   (PI.unsafeHoist lift stmSig1 P.>-> PM.store id counter1)
                                   (PI.unsafeHoist lift stmSig2 P.>-> PM.store id counter2)
                                 )
    P.>-> PM.retrieve id
    P.>-> PI.unsafeHoist lift sigConsumer -- make original consumer under IdentityT

testReactIO :: IO ()
testReactIO = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact IO: reactively yield under IO using lifted-async."
  P.runEffect $ PF._reactivelyIO (reactIOAdd
                                 (PI.unsafeHoist atomically stmSig1)
                                 (PI.unsafeHoist atomically stmSig2)
                                )
    P.>-> sigConsumer


testReactIdentityTIO :: IO ()
testReactIdentityTIO = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact IdentityT IO: reactively yield under 't IO' using lifted-async."
  runIdentityT $ P.runEffect $ PF._reactivelyIO (reactIOAdd
                                                (PI.unsafeHoist (lift . atomically) stmSig1)
                                                (PI.unsafeHoist (lift . atomically) stmSig2)
                                               )
    P.>-> hoist lift sigConsumer

testReactMerge :: IO ()
testReactMerge = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReact Merge: yield a Left/Right value depending on which producer yields a value"
  P.runEffect $ PI.unsafeHoist atomically (PF._reactively $
                                  PF.merge (PF.React stmSig1) (PF.React stmSig2)) P.>-> sigConsumer


testReactIOMerge :: IO ()
testReactIOMerge = testSig $ \stmSig1 stmSig2 -> do
  putStrLn "\nReactIO Merge: yield a Left/Right value depending on which producer yields a value"
  P.runEffect $  PF._reactivelyIO (PF.mergeIO
                                   (PF.ReactIO (PI.unsafeHoist atomically stmSig1))
                                   (PF.ReactIO (PI.unsafeHoist atomically stmSig2))) P.>-> sigConsumer

main :: IO ()
main = do
  testSync
  testReactSTM
  testReactIO
  testReactIdentityTSTM
  testReactIdentityTIO
  testReactStateTSTM
  putStrLn "\nReact StateT IO is unsafe (lift-async detect this as a compile error)"
  testReactMerge
  testReactIOMerge
