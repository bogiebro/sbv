-----------------------------------------------------------------------------
-- |
-- Module      :  TestSuite.Uninterpreted.Sort
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Test suite for uninterpreted sorts
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE ScopedTypeVariables #-}
module TestSuite.Uninterpreted.Sort where

import Data.SBV
import SBVTest
import Data.Generics

-- Test suite
testSuite :: SBVTestSuite
testSuite = mkTestSuite $ \_ -> test [
  "unint-sort" ~: assert . (==4) . length . (extractModels :: AllSatResult -> [L]) =<< allSat p0
 ]

data L = Nil | Cons Int L deriving (Eq, Ord, Data, Typeable)
instance SymWord L
instance HasKind L
instance SatModel L where
  parseCWs = undefined -- make GHC shut up about the missing method, we won't actually call it

type SList = SBV L

len :: SList -> SInteger
len = uninterpret "len"

p0 :: Symbolic SBool
p0 = do
    [l, l0, l1] <- symbolics ["l", "l0", "l1"]
    constrain $ len l0 .== 0
    constrain $ len l1 .== 1
    x :: SInteger <- symbolic "x"
    constrain $ x .== 0 ||| x.== 1
    return $ l .== l0 ||| l .== l1
