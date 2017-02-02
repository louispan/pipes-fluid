{-# OPTIONS_GHC -funbox-strict-fields #-}
{-# LANGUAGE DeriveGeneric #-}

module Pipes.Fluid.Common where

import qualified GHC.Generics as G

-- | Differentiates whether a value from either or both producers.
-- In the case of one producer, additional identify if the other producer is live or dead.
data Source = FromBoth | FromLeft !OtherStatus | FromRight !OtherStatus
    deriving (Eq, Show, Ord, G.Generic)

-- | The other producer can be live (still yielding values), or dead
data OtherStatus = OtherLive | OtherDead
    deriving (Eq, Show, Ord, G.Generic)

-- | Differentiates when only one side is available (due to initial merge values of Nothing)
-- or if two values (one of which may be a previous values) are availabe.
data Merged a b =
    Coupled !Source !a !b
    | LeftOnly !OtherStatus !a
    | RightOnly !OtherStatus !b
    deriving (Eq, Show, Ord, G.Generic)

-- | This can be used with 'Pipes.Prelude.takeWhile'
isBothLive :: Merged x y -> Bool
isBothLive (Coupled FromBoth _ _) = True
isBothLive (Coupled (FromLeft OtherLive) _ _) = True
isBothLive (Coupled (FromRight OtherLive) _ _) = True
isBothLive (LeftOnly OtherLive _) = True
isBothLive (RightOnly OtherLive _) = True
isBothLive _ = False
{-# INLINABLE isBothLive #-}

-- | This can be used with 'Pipes.Prelude.takeWhile'
isLeftLive :: Merged x y -> Bool
isLeftLive (Coupled FromBoth _ _) = True
isLeftLive (Coupled (FromLeft _) _ _) = True
isLeftLive (Coupled (FromRight OtherLive) _ _) = True
isLeftLive (LeftOnly _ _) = True
isLeftLive (RightOnly OtherLive _) = True
isLeftLive _ = False
{-# INLINABLE isLeftLive #-}

-- | This can be used with 'Pipes.Prelude.takeWhile'
isRightLive :: Merged x y -> Bool
isRightLive (Coupled FromBoth _ _) = True
isRightLive (Coupled (FromRight _) _ _) = True
isRightLive (Coupled (FromLeft OtherLive) _ _) = True
isRightLive (RightOnly _ _) = True
isRightLive (LeftOnly OtherLive _) = True
isRightLive _ = False
{-# INLINABLE isRightLive #-}

-- | This can be used with 'Pipes.Prelude.takeWhile'
isRightDead :: Merged x y -> Bool
isRightDead (Coupled (FromLeft OtherDead) _ _) = True
isRightDead (LeftOnly OtherDead _) = True
isRightDead _ = False
{-# INLINABLE isRightDead #-}

-- | This can be used with 'Pipes.Prelude.takeWhile'
isLeftDead :: Merged x y -> Bool
isLeftDead (Coupled (RightLeft OtherDead) _ _) = True
isLeftDead (RightOnly OtherDead _) = True
isLeftDead _ = False
{-# INLINABLE isLeftDead #-}
