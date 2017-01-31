{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MonomorphismRestriction #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Lens
import Control.Monad
import Control.Monad.Morph as M
import Control.Monad.State.Strict
import Control.Monad.Trans.Identity
import Data.Foldable
import Data.Maybe
import qualified Pipes as P
import qualified Pipes.Concurrent as PC
import qualified Pipes.Fluid.React as PF
import qualified Pipes.Fluid.ReactIO as PF
import qualified Pipes.Fluid.Sync as PF
import qualified Pipes.Misc.Concurrent as PM
import qualified Pipes.Misc.State.Strict as PM
import qualified Pipes.Prelude as PP
import Test.Hspec

data Model = Model
    { modelCounter1 :: Int
    , modelCounter2 :: Int
    } deriving (Eq, Show, Ord)

makeFields ''Model

data1 :: [Int]
data1 = [1, 2..9]

data2 :: [Int]
data2 = [10, 20..70]

sig1 :: Monad m => P.Producer Int m ()
sig1 = traverse_ P.yield data1

sig2 :: Monad m => P.Producer Int m ()
sig2 = traverse_ P.yield data2

delay :: Int -> P.Pipe a a IO ()
delay i = P.for P.cat $ \a -> do
  lift $ threadDelay i
  P.yield a

-- | For the Sync tests, not all the input will be consumed
-- so quitEarly will close the mailbox when an of the feeders
-- have finished feeding.
testSig' :: Bool -> (P.Producer Int STM () -> P.Producer Int STM () -> IO a) -> IO a
testSig' quitEarly f = do
    (o1, i1, q1) <- PC.spawn' $ PC.bounded 1
    (o2, i2, q2) <- PC.spawn' $ PC.bounded 1

    feederFinished1 <- newEmptyMVar
    feederFinished2 <- newEmptyMVar

    -- make time delayed signals
    void $ forkIO $ do
        P.runEffect $ sig1 P.>-> delay 30 P.>-> hoist atomically (PM.toOutputSTM o1)
        when quitEarly $ atomically $ do
            -- wait for input to be empty
            r <- PC.recv i1 <|> pure Nothing
            case r of
                Nothing -> q1 *> q2
                Just _ -> retry
        putMVar feederFinished1 ()
    void $ forkIO $ do
        P.runEffect $ sig2 P.>-> delay 50 P.>-> hoist atomically (PM.toOutputSTM o2)
        when quitEarly $ atomically $ do
            -- wait for input to be empty
            r <- PC.recv i2 <|> pure Nothing
            case r of
                Nothing -> q1 *> q2
                Just _ -> retry
        putMVar feederFinished2 ()
    -- thread to destroy PC Input when both feeders have finished
    void $ forkIO $ do
        takeMVar feederFinished1
        takeMVar feederFinished2
        atomically $ q1 *> q2
    -- run the test function
    f (PM.fromInputSTM i1) (PM.fromInputSTM i2)

main :: IO ()
main = do
    hspec $ do
        describe "Sync" $ do
            it "only yield a value when both producers yields a value" $ do
                xs <-
                    testSig' True $ \as bs ->
                        PP.toListM $
                        hoist atomically $
                        PF.synchronously $
                        (\a b -> (a, b, a + b)) <$> PF.Sync as <*> PF.Sync bs
                xs `shouldBe` (\(a, b) -> (a, b, a + b)) <$> zip data1 data2
        describe "React" $ do
            it "React STM: yield a value whenever any producer yields a value" $ do
                xs <-
                    testSig' False $ \as bs ->
                        PP.toListM $
                        hoist atomically $
                        PF.reactively $
                        (\a b -> (a, b, a + b)) <$> PF.React as <*> PF.React bs
                xs `shouldSatisfy` isBigger
            it "React IdentityT STM: reactively yields under 't STM'" $ do
                xs <-
                    testSig' False $ \as bs ->
                        runIdentityT $
                        PP.toListM $
                        hoist (hoist atomically) $
                        PF.reactively $
                        (\a b -> (a, b, a + b)) <$> (PF.React $ hoist lift as) <*>
                        (PF.React $ hoist lift bs)
                xs `shouldSatisfy` isBigger
            it "React StateT STM: reactively yields under 'StateT STM'" $ do
                xs <-
                    testSig' False $ \as bs ->
                        (`evalStateT` (Model 0 0)) $
                        PP.toListM $
                        (hoist (hoist atomically) $
                         PF.reactively $
                         (\a b -> (a, b, a + b)) <$>
                         (PF.React $ hoist lift as P.>-> PM.store id counter1) <*>
                         (PF.React $ hoist lift bs P.>-> PM.store id counter2)) P.>->
                        PM.retrieve id
                xs `shouldSatisfy` isBigger
            it "React Merge: yield a Left/Right value depending on which producer yields a value" $ do
                xs <-
                    testSig' False $ \as bs ->
                        PP.toListM $
                        hoist atomically $
                        PF.reactively $
                        PF.React as `PF.merge`PF.React bs
                xs `shouldSatisfy` isDifferent
        describe "ReactIO" $ do
            it "React IO: reactively yield under IO using lifted-async" $ do
                xs <-
                    testSig' False $ \as bs ->
                        PP.toListM $
                        PF.reactivelyIO $
                        (\a b -> (a, b, a + b)) <$> (PF.ReactIO $ hoist atomically as) <*>
                        (PF.ReactIO $ hoist atomically bs)
                xs `shouldSatisfy` isBigger
            it "React IdentityT IO: reactively yield under 't IO' using lifted-async" $ do
                xs <-
                    testSig' False $ \as bs ->
                        runIdentityT $
                        PP.toListM $
                        PF.reactivelyIO $
                        (\a b -> (a, b, a + b)) <$> (PF.ReactIO $ hoist (lift . atomically) as) <*>
                        (PF.ReactIO $ hoist (lift . atomically) bs)
                xs `shouldSatisfy` isBigger
            it "\nReact StateT IO is unsafe (lift-async detect this as a compile error)" $ do
                pure () `shouldReturn` ()
            it "ReactIO Merge: yield a Left/Right value depending on which producer yields a value" $ do
                xs <-
                    testSig' False $ \as bs ->
                        PP.toListM $
                        PF.reactivelyIO $
                        (PF.ReactIO $ hoist atomically as) `PF.mergeIO` (PF.ReactIO $ hoist atomically bs)
                xs `shouldSatisfy` isDifferent

isBigger :: Ord a => [a] -> Bool
isBigger = isJust . foldl' go (Just Nothing)
 where
   go p a =
       case p of
           Nothing -> Nothing
           Just Nothing -> Just (Just a)
           Just (Just p')
               | p' == a -> Nothing
               | p' < a -> Just (Just a)
               | otherwise -> Nothing


isDifferent :: Eq a => [a] -> Bool
isDifferent = isJust . foldl' go (Just Nothing)
  where
    go p a =
        case p of
            Nothing -> Nothing
            Just Nothing -> Just (Just a)
            Just (Just p')
                | p' == a -> Nothing
                | otherwise -> Just (Just a)
