-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BangPatterns #-}
module Cryptol.Prims.Eval where

import Cryptol.TypeCheck.AST
import Cryptol.TypeCheck.Solver.InfNat (Nat'(..),fromNat,genLog, nMul)
import qualified Cryptol.Eval.Arch as Arch
import Cryptol.Eval.Error
import Cryptol.Eval.Type(evalTF)
import Cryptol.Eval.Value
import Cryptol.Testing.Random (randomValue)
import Cryptol.Utils.Panic (panic)
import Cryptol.ModuleSystem.Name (asPrim)
import Cryptol.Utils.Ident (Ident,mkIdent)

import Data.List (sortBy, transpose, genericTake, genericDrop,
                  genericReplicate, genericSplitAt, genericIndex)
import Data.Ord (comparing)
import Data.Bits (Bits(..))

import qualified Data.Map.Strict as Map
import qualified Data.Text as T

import System.Random.TF.Gen (seedTFGen)

-- Primitives ------------------------------------------------------------------

evalPrim :: Decl -> Value
evalPrim Decl { dName = n, .. }
  | Just prim <- asPrim n, Just val <- Map.lookup prim primTable = val

evalPrim Decl { .. } =
    panic "Eval" [ "Unimplemented primitive", show dName ]

primTable :: Map.Map Ident Value
primTable = Map.fromList $ map (\(n, v) -> (mkIdent (T.pack n), v))
  [ ("+"          , binary (arithBinary (liftBinArith (+))))
  , ("-"          , binary (arithBinary (liftBinArith (-))))
  , ("*"          , binary (arithBinary (liftBinArith (*))))
  , ("/"          , binary (arithBinary (liftBinArith divWrap)))
  , ("%"          , binary (arithBinary (liftBinArith modWrap)))
  , ("^^"         , binary (arithBinary modExp))
  , ("lg2"        , unary  (arithUnary lg2))
  , ("negate"     , unary  (arithUnary negate))
  , ("<"          , binary (cmpOrder (\o -> o == LT           )))
  , (">"          , binary (cmpOrder (\o -> o == GT           )))
  , ("<="         , binary (cmpOrder (\o -> o == LT || o == EQ)))
  , (">="         , binary (cmpOrder (\o -> o == GT || o == EQ)))
  , ("=="         , binary (cmpOrder (\o ->            o == EQ)))
  , ("!="         , binary (cmpOrder (\o ->            o /= EQ)))
  , ("&&"         , binary (logicBinary (.&.)))
  , ("||"         , binary (logicBinary (.|.)))
  , ("^"          , binary (logicBinary xor))
  , ("complement" , unary  (logicUnary complement))
  , ("<<"         , logicShift shiftLW shiftLS)
  , (">>"         , logicShift shiftRW shiftRS)
  , ("<<<"        , logicShift rotateLW rotateLS)
  , (">>>"        , logicShift rotateRW rotateRS)
  , ("True"       , VBit True)
  , ("False"      , VBit False)

  , ("demote"     , ecDemoteV)

  , ("#"          , nlam $ \ front ->
                    nlam $ \ back  ->
                    tlam $ \ elty  ->
                    lam  $ \ l     ->
                    lam  $ \ r     -> ccatV front back elty l r)

  , ("@"          , indexPrimOne  indexFront)
  , ("@@"         , indexPrimMany indexFrontRange)
  , ("!"          , indexPrimOne  indexBack)
  , ("!!"         , indexPrimMany indexBackRange)

  , ("zero"       , tlam zeroV)

  , ("join"       , nlam $ \ parts ->
                    nlam $ \ each  ->
                    tlam $ \ a     -> lam (joinV parts each a))

  , ("split"      , ecSplitV)

  , ("splitAt"    , nlam $ \ front ->
                    nlam $ \ back  ->
                    tlam $ \ a     -> lam (splitAtV front back a))

  , ("fromThen"   , fromThenV)
  , ("fromTo"     , fromToV)
  , ("fromThenTo" , fromThenToV)

  , ("infFrom"    , nlam $ \(finNat'  -> bits)  ->
                     lam $ \(fromWord -> first) ->
                    toStream (map (word bits) [ first .. ]))

  , ("infFromThen", nlam $ \(finNat'  -> bits)  ->
                     lam $ \(fromWord -> first) ->
                     lam $ \(fromWord -> next)  ->
                    toStream [ word bits n | n <- [ first, next .. ] ])

  , ("error"      , tlam $ \_              ->
                    tlam $ \_              ->
                     lam $ \(fromStr -> s) -> cryUserError s)

  , ("reverse"    , nlam $ \a ->
                    tlam $ \b ->
                     lam $ \(fromSeq -> xs) -> toSeq a b (reverse xs))

  , ("transpose"  , nlam $ \a ->
                    nlam $ \b ->
                    tlam $ \c ->
                     lam $ \((map fromSeq . fromSeq) -> xs) ->
                        case a of
                           Nat 0 ->
                             let val = toSeq a c []
                             in case b of
                                  Nat n -> toSeq b (tvSeq a c) $ genericReplicate n val
                                  Inf   -> VStream $ repeat val
                           _ -> toSeq b (tvSeq a c) $ map (toSeq a c) $ transpose xs)

  , ("pmult"       ,
    let mul !res !_ !_ 0 = res
        mul  res bs as n = mul (if even as then res else xor res bs)
                               (bs `shiftL` 1) (as `shiftR` 1) (n-1)
     in nlam $ \(finNat'  -> a) ->
        nlam $ \(finNat'  -> b) ->
         lam $ \(fromWord -> x) ->
         lam $ \(fromWord -> y) -> word (max 1 (a + b) - 1) (mul 0 x y b))

  , ("pdiv"        , nlam $ \(fromInteger . finNat' -> a) ->
                     nlam $ \(fromInteger . finNat' -> b) ->
                      lam $ \(fromWord  -> x) ->
                      lam $ \(fromWord  -> y) -> word (toInteger a)
                                                      (fst (divModPoly x a y b)))

  , ("pmod"        , nlam $ \(fromInteger . finNat' -> a) ->
                     nlam $ \(fromInteger . finNat' -> b) ->
                      lam $ \(fromWord  -> x) ->
                      lam $ \(fromWord  -> y) -> word (toInteger b)
                                                      (snd (divModPoly x a y (b+1))))
  , ("random"      , tlam $ \a ->
                      lam $ \(fromWord -> x) -> randomV a x)
  ]


-- | Make a numeric constant.
ecDemoteV :: Value
ecDemoteV = nlam $ \valT ->
            nlam $ \bitT ->
            case (valT, bitT) of
              (Nat v, Nat bs) -> VWord (mkBv bs v)
              _ -> evalPanic "Cryptol.Eval.Prim.evalConst"
                       ["Unexpected Inf in constant."
                       , show valT
                       , show bitT
                       ]

--------------------------------------------------------------------------------
divModPoly :: Integer -> Int -> Integer -> Int -> (Integer, Integer)
divModPoly xs xsLen ys ysLen
  | ys == 0   = divideByZero
  | otherwise = go 0 initR (xsLen - degree) todoBits

  where
  downIxes n  = [ n - 1, n - 2 .. 0 ]

  degree      = head [ n | n <- downIxes ysLen, testBit ys n ]

  initR       = xs `shiftR` (xsLen - degree)
  nextR r b   = (r `shiftL` 1) .|. (if b then 1 else 0)

  go !res !r !bitN todo =
     let x = xor r ys
         (res',r') | testBit x degree = (res,             r)
                   | otherwise        = (setBit res bitN, x)
     in case todo of
          b : bs -> go res' (nextR r' b) (bitN-1) bs
          []     -> (res',r')

  todoBits  = map (testBit xs) (downIxes (xsLen - degree))


-- | Create a packed word
modExp :: Integer -- ^ bit size of the resulting word
       -> Integer -- ^ base
       -> Integer -- ^ exponent
       -> Integer
modExp bits base e
  | bits == 0            = 0
  | base < 0 || bits < 0 = evalPanic "modExp"
                             [ "bad args: "
                             , "  base = " ++ show base
                             , "  e    = " ++ show e
                             , "  bits = " ++ show modulus
                             ]
  | otherwise            = doubleAndAdd base e modulus
  where
  modulus = 0 `setBit` fromInteger bits

doubleAndAdd :: Integer -- ^ base
             -> Integer -- ^ exponent mask
             -> Integer -- ^ modulus
             -> Integer
doubleAndAdd base0 expMask modulus = go 1 base0 expMask
  where
  go acc base k
    | k > 0     = acc' `seq` base' `seq` go acc' base' (k `shiftR` 1)
    | otherwise = acc
    where
    acc' | k `testBit` 0 = acc `modMul` base
         | otherwise     = acc

    base' = base `modMul` base

    modMul x y = (x * y) `mod` modulus



-- Operation Lifting -----------------------------------------------------------

type GenBinary b w = TValue -> GenValue b w -> GenValue b w -> GenValue b w
type Binary = GenBinary Bool BV

binary :: GenBinary b w -> GenValue b w
binary f = tlam $ \ ty ->
            lam $ \ a  ->
            lam $ \ b  -> f ty a b

type GenUnary b w = TValue -> GenValue b w -> GenValue b w
type Unary = GenUnary Bool BV

unary :: GenUnary b w -> GenValue b w
unary f = tlam $ \ ty ->
           lam $ \ a  -> f ty a


-- Arith -----------------------------------------------------------------------

-- | Turn a normal binop on Integers into one that can also deal with a bitsize.
liftBinArith :: (Integer -> Integer -> Integer) -> BinArith
liftBinArith op _ = op

type BinArith = Integer -> Integer -> Integer -> Integer

arithBinary :: BinArith -> Binary
arithBinary op = loop
  where
  loop ty l r = case ty of

    -- words and finite sequences
    TVSeq w a
      | isTBit a  -> VWord (mkBv w (op w (fromWord l) (fromWord r)))
      | otherwise -> VSeq False (zipWith (loop a) (fromSeq l) (fromSeq r))

    -- streams
    TVStream a -> toStream (zipWith (loop a) (fromSeq l) (fromSeq r))

    -- functions
    TVFun _ ety ->
      lam $ \ x -> loop ety (fromVFun l x) (fromVFun r x)

    -- tuples
    TVTuple tys ->
      let ls = fromVTuple l
          rs = fromVTuple r
       in VTuple (zipWith3 loop tys ls rs)

    -- records
    TVRec fs ->
      VRecord [ (f, loop fty (lookupRecord f l) (lookupRecord f r))
              | (f,fty) <- fs ]

    _ -> evalPanic "arithBinop" ["Invalid arguments"]

arithUnary :: (Integer -> Integer) -> Unary
arithUnary op = loop
  where
  loop ty x = case ty of

    -- words and finite sequences
    TVSeq w a
      | isTBit a  -> VWord (mkBv w (op (fromWord x)))
      | otherwise -> VSeq False (map (loop a) (fromSeq x))

    -- infinite sequences
    TVStream a -> toStream (map (loop a) (fromSeq x))

    -- functions
    TVFun _ ety ->
      lam $ \ y -> loop ety (fromVFun x y)

    -- tuples
    TVTuple tys ->
      let as = fromVTuple x
       in VTuple (zipWith loop tys as)

    -- records
    TVRec fs ->
      VRecord [ (f, loop fty (lookupRecord f x)) | (f,fty) <- fs ]

    _ -> evalPanic "arithUnary" ["Invalid arguments"]

lg2 :: Integer -> Integer
lg2 i = case genLog i 2 of
  Just (i',isExact) | isExact   -> i'
                    | otherwise -> i' + 1
  Nothing                       -> 0

divWrap :: Integral a => a -> a -> a
divWrap _ 0 = divideByZero
divWrap x y = x `div` y

modWrap :: Integral a => a -> a -> a
modWrap _ 0 = divideByZero
modWrap x y = x `mod` y

-- Cmp -------------------------------------------------------------------------

-- | Lexicographic ordering on two values.
lexCompare :: TValue -> Value -> Value -> Ordering
lexCompare ty l r =
  case ty of
    TVBit         -> compare (fromVBit l) (fromVBit r)
    TVSeq _ TVBit -> compare (fromWord l) (fromWord r)
    TVSeq _ e     -> zipLexCompare (repeat e) (fromSeq l) (fromSeq r)
    TVTuple etys  -> zipLexCompare etys (fromVTuple l) (fromVTuple r)
    TVRec fields  ->
      let tys    = map snd (sortBy (comparing fst) fields)
          ls     = map snd (sortBy (comparing fst) (fromVRecord l))
          rs     = map snd (sortBy (comparing fst) (fromVRecord r))
       in zipLexCompare tys ls rs
    _ -> evalPanic "lexCompare" ["invalid type"]


-- XXX the lists are expected to be of the same length, as this should only be
-- used with values that come from type-correct expressions.
zipLexCompare :: [TValue] -> [Value] -> [Value] -> Ordering
zipLexCompare tys ls rs = foldr choose EQ (zipWith3 lexCompare tys ls rs)
  where
  choose c acc = case c of
    EQ -> acc
    _  -> c

-- | Process two elements based on their lexicographic ordering.
cmpOrder :: (Ordering -> Bool) -> Binary
cmpOrder op ty l r = VBit (op (lexCompare ty l r))

withOrder :: (Ordering -> TValue -> Value -> Value -> Value) -> Binary
withOrder choose ty l r = choose (lexCompare ty l r) ty l r

maxV :: Ordering -> TValue -> Value -> Value -> Value
maxV o _ l r = case o of
  LT -> r
  _  -> l

minV :: Ordering -> TValue -> Value -> Value -> Value
minV o _ l r = case o of
  GT -> r
  _  -> l


funCmp :: (Ordering -> Bool) -> Value
funCmp op =
  tlam $ \ _a ->
  tlam $ \  b ->
   lam $ \  l ->
   lam $ \  r ->
   lam $ \  x -> cmpOrder op b (fromVFun l x) (fromVFun r x)


-- Logic -----------------------------------------------------------------------

zeroV :: TValue -> Value
zeroV ty = case ty of

  -- bits
  TVBit ->
    VBit False

  -- finite sequences
  TVSeq w ety
    | isTBit ety -> word w 0
    | otherwise  -> toFinSeq ety (replicate (fromInteger w) (zeroV ety))

  -- infinite sequences
  TVStream ety -> toStream (repeat (zeroV ety))

  -- functions
  TVFun _ bty ->
    lam (\ _ -> zeroV bty)

  -- tuples
  TVTuple tys ->
    VTuple (map zeroV tys)

  -- records
  TVRec fields ->
    VRecord [ (f,zeroV fty) | (f,fty) <- fields ]


-- | Join a sequence of sequences into a single sequence.
joinV :: Nat' -> Nat' -> TValue -> Value -> Value
joinV parts each a val =
  let len = parts `nMul` each
  in toSeq len a (concatMap fromSeq (fromSeq val))

splitAtV :: Nat' -> Nat' -> TValue -> Value -> Value
splitAtV front back a val =
  case back of

    -- Remember that words are big-endian in cryptol, so the first component
    -- needs to be shifted, and the second component just needs to be masked.
    Nat rightWidth | aBit, VWord (BV _ i) <- val ->
          VTuple [ VWord (BV leftWidth (i `shiftR` fromInteger rightWidth))
                 , VWord (mkBv rightWidth i) ]

    _ ->
      let (ls,rs) = genericSplitAt leftWidth (fromSeq val)
       in VTuple [VSeq aBit ls, toSeq back a rs]

  where

  aBit = isTBit a

  leftWidth = case front of
    Nat n -> n
    _     -> evalPanic "splitAtV" ["invalid `front` len"]


-- | Split implementation.
ecSplitV :: Value
ecSplitV =
  nlam $ \ parts ->
  nlam $ \ each  ->
  tlam $ \ a     ->
  lam  $ \ val ->
  let mkChunks f = map (toFinSeq a) $ f $ fromSeq val
  in case (parts, each) of
       (Nat p, Nat e) -> VSeq False $ mkChunks (finChunksOf p e)
       (Inf  , Nat e) -> toStream   $ mkChunks (infChunksOf e)
       _              -> evalPanic "splitV" ["invalid type arguments to split"]

-- | Split into infinitely many chunks
infChunksOf :: Integer -> [a] -> [[a]]
infChunksOf each xs = let (as,bs) = genericSplitAt each xs
                      in as : infChunksOf each bs

-- | Split into finitely many chunks
finChunksOf :: Integer -> Integer -> [a] -> [[a]]
finChunksOf 0 _ _ = []
finChunksOf parts each xs = let (as,bs) = genericSplitAt each xs
                            in as : finChunksOf (parts - 1) each bs


ccatV :: Nat' -> Nat' -> TValue -> Value -> Value -> Value
ccatV _front _back (isTBit -> True) (VWord (BV i x)) (VWord (BV j y)) =
  VWord (BV (i + j) (shiftL x (fromInteger j) + y))
ccatV front back elty l r =
  toSeq (evalTF TCAdd [front,back]) elty (fromSeq l ++ fromSeq r)

-- | Merge two values given a binop.  This is used for and, or and xor.
logicBinary :: (forall a. Bits a => a -> a -> a) -> Binary
logicBinary op = loop
  where
  loop ty l r = case ty of
    TVBit -> VBit (op (fromVBit l) (fromVBit r))
    -- words or finite sequences
    TVSeq w aty
      | isTBit aty -> VWord (BV w (op (fromWord l) (fromWord r)))
                      -- We assume that bitwise ops do not need re-masking
      | otherwise -> VSeq False (zipWith (loop aty) (fromSeq l)
                                                    (fromSeq r))

    -- streams
    TVStream aty -> toStream (zipWith (loop aty) (fromSeq l) (fromSeq r))

    TVTuple etys ->
      let ls = fromVTuple l
          rs = fromVTuple r
       in VTuple (zipWith3 loop etys ls rs)

    TVFun _ bty ->
      lam $ \ a -> loop bty (fromVFun l a) (fromVFun r a)

    TVRec fields ->
      VRecord [ (f,loop fty a b) | (f,fty) <- fields
                                 , let a = lookupRecord f l
                                       b = lookupRecord f r
                                 ]

logicUnary :: (forall a. Bits a => a -> a) -> Unary
logicUnary op = loop
  where
  loop ty val = case ty of
    TVBit -> VBit (op (fromVBit val))

    -- words or finite sequences
    TVSeq w ety
      | isTBit ety -> VWord (mkBv w (op (fromWord val)))
      | otherwise -> VSeq False (map (loop ety) (fromSeq val))

    -- streams
    TVStream ety -> toStream (map (loop ety) (fromSeq val))

    TVTuple etys ->
      let as = fromVTuple val
       in VTuple (zipWith loop etys as)

    TVFun _ bty ->
      lam $ \ a -> loop bty (fromVFun val a)

    TVRec fields ->
      VRecord [ (f,loop fty a) | (f,fty) <- fields, let a = lookupRecord f val ]


logicShift :: (Integer -> Integer -> Integer -> Integer)
              -- ^ The function may assume its arguments are masked.
              -- It is responsible for masking its result if needed.
           -> (Nat' -> TValue -> [Value] -> Integer -> [Value])
           -> Value
logicShift opW opS
  = nlam $ \ a ->
    tlam $ \ _ ->
    tlam $ \ c ->
     lam  $ \ l ->
     lam  $ \ r ->
        if isTBit c
          then -- words
            let BV w i  = fromVWord l
            in VWord (BV w (opW w i (fromWord r)))

          else toSeq a c (opS a c (fromSeq l) (fromWord r))

-- Left shift for words.
shiftLW :: Integer -> Integer -> Integer -> Integer
shiftLW w ival by
  | by >= w   = 0
  | otherwise = mask w (shiftL ival (fromInteger by))

shiftLS :: Nat' -> TValue -> [Value] -> Integer -> [Value]
shiftLS w ety vs by =
  case w of
    Nat len
      | by < len  -> genericTake len (genericDrop by vs ++ repeat (zeroV ety))
      | otherwise -> genericReplicate len (zeroV ety)
    Inf           -> genericDrop by vs

shiftRW :: Integer -> Integer -> Integer -> Integer
shiftRW w i by
  | by >= w   = 0
  | otherwise = shiftR i (fromInteger by)

shiftRS :: Nat' -> TValue -> [Value] -> Integer -> [Value]
shiftRS w ety vs by =
  case w of
    Nat len
      | by < len  -> genericTake len (genericReplicate by (zeroV ety) ++ vs)
      | otherwise -> genericReplicate len (zeroV ety)
    Inf           -> genericReplicate by (zeroV ety) ++ vs

-- XXX integer doesn't implement rotateL, as there's no bit bound
rotateLW :: Integer -> Integer -> Integer -> Integer
rotateLW 0 i _  = i
rotateLW w i by = mask w $ (i `shiftL` b) .|. (i `shiftR` (fromInteger w - b))
  where b = fromInteger (by `mod` w)

rotateLS :: Nat' -> TValue -> [Value] -> Integer -> [Value]
rotateLS w _ vs at =
  case w of
    Nat len -> let at'     = at `mod` len
                   (ls,rs) = genericSplitAt at' vs
                in rs ++ ls
    _ -> panic "Cryptol.Eval.Prim.rotateLS" [ "unexpected infinite sequence" ]

-- XXX integer doesn't implement rotateR, as there's no bit bound
rotateRW :: Integer -> Integer -> Integer -> Integer
rotateRW 0 i _  = i
rotateRW w i by = mask w $ (i `shiftR` b) .|. (i `shiftL` (fromInteger w - b))
  where b = fromInteger (by `mod` w)

rotateRS :: Nat' -> TValue -> [Value] -> Integer -> [Value]
rotateRS w _ vs at =
  case w of
    Nat len -> let at'     = at `mod` len
                   (ls,rs) = genericSplitAt (len - at') vs
                in rs ++ ls
    _ -> panic "Cryptol.Eval.Prim.rotateRS" [ "unexpected infinite sequence" ]


-- Sequence Primitives ---------------------------------------------------------

-- | Indexing operations that return one element.
indexPrimOne :: (Maybe Integer -> [Value] -> Integer -> Value) -> Value
indexPrimOne op =
  nlam $ \ n  ->
  tlam $ \ _a ->
  nlam $ \ _i ->
   lam $ \ l  ->
   lam $ \ r  ->
     let vs  = fromSeq l
         ix  = fromWord r
      in op (fromNat n) vs ix

indexFront :: Maybe Integer -> [Value] -> Integer -> Value
indexFront mblen vs ix =
  case mblen of
    Just len | len <= ix -> invalidIndex ix
    _                    -> genericIndex vs ix

indexBack :: Maybe Integer -> [Value] -> Integer -> Value
indexBack mblen vs ix =
  case mblen of
    Just len | len > ix  -> genericIndex vs (len - ix - 1)
             | otherwise -> invalidIndex ix
    Nothing              -> evalPanic "indexBack"
                            ["unexpected infinite sequence"]

-- | Indexing operations that return many elements.
indexPrimMany :: (Maybe Integer -> [Value] -> [Integer] -> [Value]) -> Value
indexPrimMany op =
  nlam $ \ n  ->
  tlam $ \ a  ->
  nlam $ \ m  ->
  tlam $ \ _i ->
   lam $ \ l  ->
   lam $ \ r  ->
     let vs    = fromSeq l
         ixs   = map fromWord (fromSeq r)
     in toSeq m a (op (fromNat (n)) vs ixs)

indexFrontRange :: Maybe Integer -> [Value] -> [Integer] -> [Value]
indexFrontRange mblen vs = map (indexFront mblen vs)

indexBackRange :: Maybe Integer -> [Value] -> [Integer] -> [Value]
indexBackRange mblen vs = map (indexBack mblen vs)

-- @[ 0, 1 .. ]@
fromThenV :: Value
fromThenV  =
  nlam $ \ first ->
  nlam $ \ next  ->
  nlam $ \ bits  ->
  nlam $ \ len   ->
    case (first, next, len, bits) of
      (_         , _        , _       , Nat bits')
        | bits' >= Arch.maxBigIntWidth -> wordTooWide bits'
      (Nat first', Nat next', Nat len', Nat bits') ->
        let nums = enumFromThen first' next'
         in VSeq False (genericTake len' (map (VWord . BV bits') nums))
      _ -> evalPanic "fromThenV" ["invalid arguments"]

-- @[ 0 .. 10 ]@
fromToV :: Value
fromToV  =
  nlam $ \ first ->
  nlam $ \ lst   ->
  nlam $ \ bits  ->
    case (first, lst, bits) of
      (_         , _       , Nat bits')
        | bits' >= Arch.maxBigIntWidth -> wordTooWide bits'
      (Nat first', Nat lst', Nat bits') ->
        let nums = enumFromThenTo first' (first' + 1) lst'
            len  = 1 + (lst' - first')
         in VSeq False (genericTake len (map (VWord . BV bits') nums))

      _ -> evalPanic "fromThenV" ["invalid arguments"]

-- @[ 0, 1 .. 10 ]@
fromThenToV :: Value
fromThenToV  =
  nlam $ \ first ->
  nlam $ \ next  ->
  nlam $ \ lst   ->
  nlam $ \ bits  ->
  nlam $ \ len   ->
    case (first, next, lst, len, bits) of
      (_         , _        , _       , _       , Nat bits')
        | bits' >= Arch.maxBigIntWidth -> wordTooWide bits'
      (Nat first', Nat next', Nat lst', Nat len', Nat bits') ->
        let nums = enumFromThenTo first' next' lst'
         in VSeq False (genericTake len' (map (VWord . BV bits') nums))

      _ -> evalPanic "fromThenV" ["invalid arguments"]

-- Random Values ---------------------------------------------------------------

-- | Produce a random value with the given seed. If we do not support
-- making values of the given type, return zero of that type.
-- TODO: do better than returning zero
randomV :: TValue -> Integer -> Value
randomV ty seed =
  case randomValue (tValTy ty) of
    Nothing -> zeroV ty
    Just gen ->
      -- unpack the seed into four Word64s
      let mask64 = 0xFFFFFFFFFFFFFFFF
          unpack s = fromIntegral (s .&. mask64) : unpack (s `shiftR` 64)
          [a, b, c, d] = take 4 (unpack seed)
      in fst $ gen 100 $ seedTFGen (a, b, c, d)
