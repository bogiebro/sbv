-----------------------------------------------------------------------------
-- |
-- Module      :  Main
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- SBV library basic test suite; i.e., those tests that do not
-- require the use of an external SMT solver.
-----------------------------------------------------------------------------

-- Nothing needs to be changed in this file, add test cases
-- appropriately to SBVUnitTest.hs file, and they will be
-- picked up here automagically
module Main(main) where

import Control.Monad    (unless, when)
import System.Directory (doesDirectoryExist)
import System.Exit      (exitWith, exitSuccess, ExitCode(..))
import System.FilePath  ((</>))
import System.IO        (stderr, hPutStrLn)
import Test.HUnit       (Test(..), Counts(..), runTestText, PutText(..), showCounts)

import Data.Version     (showVersion)
import SBVTest          (SBVTestSuite(..), generateGoldCheck)
import Paths_sbv        (getDataDir, version)

import SBVTestCollection    (allTestCases)
import SBVUnitTestBuildTime (buildTime)

testCollection :: [(String, SBVTestSuite)]
testCollection = [(n, s) | (n, False, s) <- allTestCases]

main :: IO ()
main = do putStrLn $ "*** SBVBasicTester, version: " ++ showVersion version ++ ", time stamp: " ++ buildTime
          d <- getDataDir 
          run $ d </> "SBVUnitTest" </> "GoldFiles"

checkGoldDir :: FilePath -> IO ()
checkGoldDir gd = do e <- doesDirectoryExist gd
                     unless e $ do putStrLn "*** Cannot locate gold file repository!"
                                   putStrLn "*** Please call with one argument, the directory name of the gold files."
                                   putStrLn "*** Cannot run test cases, exiting."
                                   exitWith $ ExitFailure 1

run :: FilePath -> IO ()
run gd = do putStrLn $ "*** Starting SBV basic tests..\n*** Gold files at: " ++ show gd
            checkGoldDir gd
            (cts, _) <- runTestText (PutText put ()) $ TestList $ map (mkTst . snd) testCollection
            hPutStrLn stderr $ showCounts cts
            decide cts
  where mkTst (SBVTestSuite f) = f $ generateGoldCheck gd False
        put s _ st = length s `seq` return st

decide :: Counts -> IO ()
decide (Counts c t e f) = do
        when (c /= t) $ putStrLn $ "*** Not all test cases were tried. (Only tested " ++ show t ++ " of " ++ show c ++ ")"
        when (e /= 0) $ putStrLn $ "*** " ++ show e ++ " (of " ++ show c ++ ") test cases in error."
        when (f /= 0) $ putStrLn $ "*** " ++ show f ++ " (of " ++ show c ++ ") test cases failed."
        if c == t && e == 0 && f == 0
           then do putStrLn $ "All " ++ show c ++ " test cases successfully passed."
                   exitSuccess
           else exitWith $ ExitFailure 2
