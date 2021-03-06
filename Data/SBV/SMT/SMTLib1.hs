-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.SMT.SMTLib1
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Conversion of symbolic programs to SMTLib format, Using v1 of the standard
-----------------------------------------------------------------------------
{-# LANGUAGE PatternGuards #-}

module Data.SBV.SMT.SMTLib1(cvt, addNonEqConstraints) where

import qualified Data.Foldable as F   (toList)
import qualified Data.Set      as Set
import Data.List  (intercalate)

import Data.SBV.BitVectors.Data

-- | Add constraints to generate /new/ models. This function is used to query the SMT-solver, while
-- disallowing a previous model.
addNonEqConstraints :: RoundingMode -> [[(String, CW)]] -> SMTLibPgm -> Maybe String
addNonEqConstraints _rm nonEqConstraints (SMTLibPgm _ (aliasTable, pre, post)) = Just $ intercalate "\n" $
     pre
  ++ [ " ; --- refuted-models ---" ]
  ++ concatMap nonEqs (map (map intName) nonEqConstraints)
  ++ post
 where intName (s, c)
          | Just sw <- s `lookup` aliasTable = (show sw, c)
          | True                             = (s, c)

nonEqs :: [(String, CW)] -> [String]
nonEqs []     =  []
nonEqs [sc]   =  [" :assumption " ++ nonEq sc]
nonEqs (sc:r) =  [" :assumption (or " ++ nonEq sc]
              ++ map (("                 " ++) . nonEq) r
              ++ ["             )"]

nonEq :: (String, CW) -> String
nonEq (s, c) = "(not (= " ++ s ++ " " ++ cvtCW c ++ "))"

-- | Translate a problem into an SMTLib1 script
cvt :: RoundingMode                 -- ^ User selected rounding mode to be used for floating point arithmetic
    -> Maybe Logic                  -- ^ SMT-Lib logic, if requested by the user
    -> SolverCapabilities           -- ^ capabilities of the current solver
    -> Set.Set Kind                 -- ^ kinds used
    -> Bool                         -- ^ is this a sat problem?
    -> [String]                     -- ^ extra comments to place on top
    -> [(Quantifier, NamedSymVar)]  -- ^ inputs
    -> [Either SW (SW, [SW])]       -- ^ skolemized version of the inputs
    -> [(SW, CW)]                   -- ^ constants
    -> [((Int, Kind, Kind), [SW])]  -- ^ auto-generated tables
    -> [(Int, ArrayInfo)]           -- ^ user specified arrays
    -> [(String, SBVType)]          -- ^ uninterpreted functions/constants
    -> [(String, [String])]         -- ^ user given axioms
    -> SBVPgm                       -- ^ assignments
    -> [SW]                         -- ^ extra constraints
    -> SW                           -- ^ output variable
    -> ([String], [String])
cvt _roundingMode smtLogic _solverCaps _kindInfo isSat comments qinps _skolemInps consts tbls arrs uis axs asgnsSeq cstrs out = (pre, post)
  where logic
         | Just l <- smtLogic                 = show l
         | null tbls && null arrs && null uis = "QF_BV"
         | True                               = "QF_AUFBV"
        inps = map (fst . snd) qinps
        pre =    [ "; Automatically generated by SBV. Do not edit." ]
              ++ map ("; " ++) comments
              ++ ["(benchmark sbv"
                 , " :logic " ++ logic
                 , " :status unknown"
                 , " ; --- inputs ---"
                 ]
              ++ map decl inps
              ++ [ " ; --- declarations ---" ]
              ++ map (decl . fst) consts
              ++ map (decl . fst) asgns
              ++ [ " ; --- constants ---" ]
              ++ map cvtCnst consts
              ++ [ " ; --- tables ---" ]
              ++ concatMap mkTable tbls
              ++ [ " ; --- arrays ---" ]
              ++ concatMap declArray arrs
              ++ [ " ; --- uninterpreted constants ---" ]
              ++ concatMap declUI uis
              ++ [ " ; --- user given axioms ---" ]
              ++ map declAx axs
              ++ [ " ; --- assignments ---" ]
              ++ map cvtAsgn asgns
        post =    [ " ; --- constraints ---" ]
               ++ map mkCstr cstrs
               ++ [ " ; --- formula ---" ]
               ++ [mkFormula isSat out]
               ++ [")"]
        asgns = F.toList (pgmAssignments asgnsSeq)
        mkCstr s = " :assumption " ++ show s

-- TODO: Does this work for SMT-Lib when the index/element types are signed?
-- Currently we ignore the signedness of the arguments, as there appears to be no way
-- to capture that in SMT-Lib; and likely it does not matter. Would be good to check
-- explicitly though.
mkTable :: ((Int, Kind, Kind), [SW]) -> [String]
mkTable ((i, ak, rk), elts) = (" :extrafuns ((" ++ t ++ " Array[" ++ show at ++ ":" ++ show rt ++ "]))") : zipWith mkElt elts [(0::Int)..]
  where t = "table" ++ show i
        mkElt x k = " :assumption (= (select " ++ t ++ " bv" ++ show k ++ "[" ++ show at ++ "]) " ++ show x ++ ")"
        (at, rt) = case (ak, rk) of
                     (KBounded _ a, KBounded _ b) -> (a, b)
                     _                            -> die $ "mkTable: Unbounded table component: " ++ show (ak, rk)

-- Unexpected input, or things we will probably never support
die :: String -> a
die msg = error $ "SBV->SMTLib1: Unexpected: " ++ msg

declArray :: (Int, ArrayInfo) -> [String]
declArray (i, (_, (ak, rk), ctx)) = adecl : ctxInfo
  where nm = "array_" ++ show i
        adecl = " :extrafuns ((" ++ nm ++ " Array[" ++ show at ++ ":" ++ show rt ++ "]))"
        (at, rt) = case (ak, rk) of
                     (KBounded _ a, KBounded _ b) -> (a, b)
                     _                            -> die $ "declArray: Unbounded array component: " ++ show (ak, rk)
        ctxInfo = case ctx of
                    ArrayFree Nothing   -> []
                    ArrayFree (Just sw) -> declA sw
                    ArrayReset _ sw     -> declA sw
                    ArrayMutate j a b -> [" :assumption (= " ++ nm ++ " (store array_" ++ show j ++ " " ++ show a ++ " " ++ show b ++ "))"]
                    ArrayMerge  t j k -> [" :assumption (= " ++ nm ++ " (ite " ++ show t ++ " array_" ++ show j ++ " array_" ++ show k ++ "))"]
        declA sw = let iv = nm ++ "_freeInitializer"
                   in [ " :extrafuns ((" ++ iv ++ " " ++ kindType ak ++ "))"
                      , " :assumption (= (select " ++ nm ++ " " ++ iv ++ ") " ++ show sw ++ ")"
                      ]

declAx :: (String, [String]) -> String
declAx (nm, ls) = (" ;; -- user given axiom: " ++ nm ++ "\n   ") ++ intercalate "\n   " ls

declUI :: (String, SBVType) -> [String]
declUI (i, t) = [" :extrafuns ((uninterpreted_" ++ i ++ " " ++ cvtType t ++ "))"]

mkFormula :: Bool -> SW -> String
mkFormula isSat s
 | isSat = " :formula " ++ show s
 | True  = " :formula (not " ++ show s ++ ")"

-- SMTLib represents signed/unsigned quantities with the same type
decl :: SW -> String
decl s
 | isBoolean s = " :extrapreds ((" ++ show s ++ "))"
 | True        = " :extrafuns  ((" ++ show s ++ " " ++ kindType (kindOf s) ++ "))"

cvtAsgn :: (SW, SBVExpr) -> String
cvtAsgn (s, e) = " :assumption (= " ++ show s ++ " " ++ cvtExp e ++ ")"

cvtCnst :: (SW, CW) -> String
cvtCnst (s, c) = " :assumption (= " ++ show s ++ " " ++ cvtCW c ++ ")"

-- no need to worry about Int/Real here as we don't support them with the SMTLib1 interface..
cvtCW :: CW -> String
cvtCW (CW KBool (CWInteger v)) = if v == 0 then "false" else "true"
cvtCW x@(CW _ (CWInteger v)) | not (hasSign x) = "bv" ++ show v ++ "[" ++ show (intSizeOf x) ++ "]"
-- signed numbers (with 2's complement representation) is problematic
-- since there's no way to put a bvneg over a positive number to get minBound..
-- Hence, we punt and use binary notation in that particular case
cvtCW x@(CW _ (CWInteger v))  | v == least = mkMinBound (intSizeOf x)
  where least = negate (2 ^ intSizeOf x)
cvtCW x@(CW _ (CWInteger v)) = negIf (v < 0) $ "bv" ++ show (abs v) ++ "[" ++ show (intSizeOf x) ++ "]"
cvtCW x = error $ "SBV.SMTLib1.cvtCW: Unexpected CW: " ++ show x -- unbounded/real, shouldn't reach here

negIf :: Bool -> String -> String
negIf True  a = "(bvneg " ++ a ++ ")"
negIf False a = a

-- anamoly at the 2's complement min value! Have to use binary notation here
-- as there is no positive value we can provide to make the bvneg work.. (see above)
mkMinBound :: Int -> String
mkMinBound i = "bv1" ++ replicate (i-1) '0' ++ "[" ++ show i ++ "]"

rot :: String -> Int -> SW -> String
rot o c x = "(" ++ o ++ "[" ++ show c ++ "] " ++ show x ++ ")"

-- only used for bounded SWs
shft :: String -> String -> Int -> SW -> String
shft oW oS c x = "(" ++ o ++ " " ++ show x ++ " " ++ cvtCW c' ++ ")"
   where s  = hasSign x
         c' = mkConstCW (kindOf x) c
         o  = if s then oS else oW

cvtExp :: SBVExpr -> String
cvtExp (SBVApp Ite [a, b, c]) = "(ite " ++ show a ++ " " ++ show b ++ " " ++ show c ++ ")"
cvtExp (SBVApp (Rol i) [a])   = rot "rotate_left"  i a
cvtExp (SBVApp (Ror i) [a])   = rot "rotate_right" i a
cvtExp (SBVApp (Shl i) [a])   = shft "bvshl"  "bvshl"  i a
cvtExp (SBVApp (Shr i) [a])   = shft "bvlshr" "bvashr" i a
cvtExp (SBVApp (SShr i) [a])  = shft "bvashr" "bvashr" i a
cvtExp (SBVApp (LkUp (t, ak, _, l) i e) [])
  | needsCheck = "(ite " ++ cond ++ show e ++ " " ++ lkUp ++ ")"
  | True       = lkUp
  where at = case ak of
              KBounded _ n -> n
              _            -> die $ "cvtExp: Unbounded lookup component" ++ show ak
        needsCheck = (2::Integer)^at > fromIntegral l
        lkUp = "(select table" ++ show t ++ " " ++ show i ++ ")"
        cond
         | hasSign i = "(or " ++ le0 ++ " " ++ gtl ++ ") "
         | True      = gtl ++ " "
        (less, leq) = if hasSign i then ("bvslt", "bvsle") else ("bvult", "bvule")
        mkCnst = cvtCW . mkConstCW (kindOf i)
        le0  = "(" ++ less ++ " " ++ show i ++ " " ++ mkCnst 0 ++ ")"
        gtl  = "(" ++ leq  ++ " " ++ mkCnst l ++ " " ++ show i ++ ")"
cvtExp (SBVApp (Extract i j) [a]) = "(extract[" ++ show i ++ ":" ++ show j ++ "] " ++ show a ++ ")"
cvtExp (SBVApp (ArrEq i j) []) = "(= array_" ++ show i ++ " array_" ++ show j ++")"
cvtExp (SBVApp (ArrRead i) [a]) = "(select array_" ++ show i ++ " " ++ show a ++ ")"
cvtExp (SBVApp (Uninterpreted nm) [])   = "uninterpreted_" ++ nm
cvtExp (SBVApp (Uninterpreted nm) args) = "(uninterpreted_" ++ nm ++ " " ++ unwords (map show args) ++ ")"
cvtExp inp@(SBVApp op args)
  | Just f <- lookup op smtOpTable
  = f (any hasSign args) (all isBoolean args) (map show args)
  | True
  = error $ "SBV.SMT.SMTLib1.cvtExp: impossible happened; can't translate: " ++ show inp
  where lift2  o _ _ [x, y] = "(" ++ o ++ " " ++ x ++ " " ++ y ++ ")"
        lift2  o _ _ sbvs   = error $ "SBV.SMTLib1.cvtExp.lift2: Unexpected arguments: "   ++ show (o, sbvs)
        lift2S oU oS sgn isB sbvs
          | sgn
          = lift2 oS sgn isB sbvs
          | True
          = lift2 oU sgn isB sbvs
        lift1  o _ _ [x]    = "(" ++ o ++ " " ++ x ++ ")"
        lift1  o _ _ sbvs   = error $ "SBV.SMT.SMTLib1.cvtExp.lift1: Unexpected arguments: "   ++ show (o, sbvs)
        -- ops that distinguish 1-bit bitvectors (boolean) from others
        lift2B bOp vOp sgn isB sbvs
          | isB
          = lift2 bOp sgn isB sbvs
          | True
          = lift2 vOp sgn isB sbvs
        lift1B bOp vOp sgn isB sbvs
          | isB
          = lift1 bOp sgn isB sbvs
          | True
          = lift1 vOp sgn isB sbvs
        eq sgn isB sbvs
          | isB
          = lift2 "=" sgn isB sbvs
          | True
          = "(= " ++ lift2 "bvcomp" sgn isB sbvs ++ " bv1[1])"
        neq sgn isB sbvs = "(not " ++ eq sgn isB sbvs ++ ")"
        smtOpTable = [ (Plus,          lift2   "bvadd")
                     , (Minus,         lift2   "bvsub")
                     , (Times,         lift2   "bvmul")
                     , (Quot,          lift2S  "bvudiv" "bvsdiv")
                     , (SQuot,         lift2   "bvsdiv")
                     , (Rem,           lift2S  "bvurem" "bvsrem")
                     , (SRem,          lift2   "bvsrem")
                     , (Equal,         eq)
                     , (NotEqual,      neq)
                     , (LessThan,      lift2S  "bvult" "bvslt")
                     , (SLessThan,     lift2   "bvslt")
                     , (GreaterThan,   lift2S  "bvugt" "bvsgt")
                     , (SGreaterThan,  lift2   "bvsgt")
                     , (LessEq,        lift2S  "bvule" "bvsle")
                     , (SLessEq,       lift2   "bvsle")
                     , (GreaterEq,     lift2S  "bvuge" "bvsge")
                     , (SGreaterEq,    lift2   "bvsge")
                     , (And,           lift2B  "and" "bvand")
                     , (Or,            lift2B  "or"  "bvor")
                     , (Not,           lift1B  "not" "bvnot")
                     , (XOr,           lift2B  "xor" "bvxor")
                     , (Join,          lift2   "concat")
                     , (SymShr,        lift2   "bvlshr")
                     , (SymShl,        lift2   "bvshr")
                     , (SSymShr,       lift2   "bvashr")
                     ]

cvtType :: SBVType -> String
cvtType (SBVType []) = error "SBV.SMT.SMTLib1.cvtType: internal: received an empty type!"
cvtType (SBVType xs) = unwords $ map kindType xs

kindType :: Kind -> String
kindType KBool              = "Bool"
kindType (KBounded _ s)     = "BitVec[" ++ show s ++ "]"
kindType KUnbounded         = die "unbounded Integer"
kindType KReal              = die "real value"
kindType KFloat             = die "float value"
kindType KDouble            = die "double value"
kindType (KUninterpreted s) = die $ "uninterpreted sort: " ++ s
