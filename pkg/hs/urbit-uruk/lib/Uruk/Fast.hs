{-# OPTIONS_GHC -funbox-strict-fields -Werror #-}

{-
    TODO Fill out callNodeFull.
    TODO K should not evaluate tail.
    TODO Implement pattern-match registers.

    Note that On 64 bit machines, GHC will always use pointer tagging
    as long as there are less than 8 constructors. So, anything that is
    frequently pattern matched on should have at most 7 branches.
-}

module Uruk.Fast where

import ClassyPrelude        hiding (evaluate, fromList, try)
import Data.Primitive.Array
import System.IO.Unsafe

import Control.Arrow    ((>>>))
import Data.Bits        (shiftL, (.|.))
import Data.Flat
import Data.Function    ((&))
import Numeric.Natural  (Natural)
import Numeric.Positive (Positive)
import Prelude          ((!!))
import Uruk.JetDemo     (Ur, UrPoly(Fast))

import qualified Urbit.Atom   as Atom
import qualified Uruk.JetComp as Comp
import qualified Uruk.JetDemo as Ur

import qualified GHC.Exts


-- Useful Types ----------------------------------------------------------------

type Nat = Natural
type Bol = Bool
type Pos = Positive

type IOArray = MutableArray RealWorld


-- Raw Uruk (Basically just used for D (jam)) ----------------------------------

data Pri = J | K | S | D
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (Flat, NFData)

data Raw = Raw !Pri ![Raw]
  deriving stock    (Eq, Ord, Show, Generic)
  deriving anyclass (Flat, NFData)

jamRaw :: Raw -> Val
jamRaw = VNat . Atom.bytesAtom . flat

toRaw :: Val -> Raw
toRaw = valFun >>> \case
  Fun _ f xs -> app (nodeRaw f) (GHC.Exts.toList $ toRaw <$> xs)
 where
  --  Doesn't need to be simplified because input is already fully
  --  evaluated.
  app :: Raw -> [Raw] -> Raw
  app (Raw f xs) mor = Raw f (xs <> mor)

nodeRaw :: Node -> Raw
nodeRaw = \case
  Jay 1 -> Raw J []
  Kay   -> Raw K []
  Ess   -> Raw S []
  Dee   -> Raw D []
  _     -> error "TODO"

priFun :: Pri -> (Int, Node)
priFun = \case
  S -> (3, Seq)
  K -> (2, Kay)
  J -> (1, Jay 1)
  D -> (1, Dee)

rawVal :: Raw -> Val
{-# INLINE rawVal #-}
rawVal (Raw p xs) = VFun $ Fun (args - sizeofArray vals) node vals
 where
  (args, node) = priFun p
  vals         = rawVal <$> fromList xs

jam :: Val -> Val
{-# INLINE jam #-}
jam = jamRaw . toRaw


-- Types -----------------------------------------------------------------------

data Jet = Jet
  { jArgs :: !Int
  , jName :: Val
  , jBody :: Val
  , jFast :: !Exp
  , jRegs :: !Int -- Number of registers needed.
  }
 deriving (Eq, Ord, Show)

data Node
  = Jay Pos
  | Kay
  | Ess
  | Dee
  | Jut Jet
  | Eye
  | Bee
  | Sea
  | Sen Pos
  | Ben Pos
  | Cen Pos
  | Seq
  | Yet Nat
  | Fix
  | Nat Nat
  | Bol Bool
  | Iff
  | Pak
  | Zer
  | Eql
  | Add
  | Inc
  | Dec
  | Fec
  | Mul
  | Sub
  | Ded
  | Uni
  | Lef
  | Rit
  | Cas
  | Con
  | Car
  | Cdr
 deriving stock (Eq, Ord, Show)

data Fun = Fun
  { fNeed :: !Int
  , fHead :: !Node
  , fArgs :: Array Val -- Lazy on purpose.
  }
 deriving stock (Eq, Ord, Show)

data Val
  = VUni
  | VCon !Val !Val
  | VLef !Val
  | VRit !Val
  | VNat !Nat
  | VBol !Bool
  | VFun !Fun
 deriving (Eq, Ord, Show)

data Exp
  = VAL !Val                      --  Constant Value
  | REF !Int                      --  Stack Reference
  | REC1 !Exp                     --  Recursive Call
  | REC2 !Exp !Exp                --  Recursive Call
  | REC3 !Exp !Exp !Exp           --  Recursive Call
  | REC4 !Exp !Exp !Exp !Exp      --  Recursive Call
  | RECN !(Array Exp)             --  Recursive Call
  | SLF                           --  Self Reference
  | IFF !Exp !Exp !Exp            --  If-Then-Else
  | CAS !Int !Exp !Exp !Exp       --  Pattern Match

  | SEQ !Exp !Exp                 --  Evaluate head, return tail
  | DED !Exp                      --  Evaluate argument, then crash.

  | INC !Exp                      --  Increment
  | DEC !Exp                      --  Decrement
  | FEC !Exp                      --  Fast decrement
  | ADD !Exp !Exp                 --  Add
  | MUL !Exp !Exp                 --  Multiply
  | SUB !Exp !Exp                 --  Subtract
  | ZER !Exp                      --  Is Zero?
  | EQL !Exp !Exp                 --  Atom equality.

  | CON !Exp !Exp                 --  Cons
  | CAR !Exp                      --  Head
  | CDR !Exp                      --  Tail
  | LEF !Exp                      --  Left Constructor
  | RIT !Exp                      --  Right Constructor

  | JET1 !Jet !Exp                --  Fully saturated jet call.
  | JET2 !Jet !Exp !Exp           --  Fully saturated jet call.
  | JET3 !Jet !Exp !Exp !Exp      --  Fully saturated jet call.
  | JET4 !Jet !Exp !Exp !Exp !Exp --  Fully saturated jet call.
  | JETN !Jet !(Array Exp)        --  Fully saturated jet call.

  | CLON !Fun !(Array Exp)        --  Undersaturated call
  | CALN !Exp !(Array Exp)        --  Call of unknown saturation
 deriving (Eq, Ord, Show)


-- Exceptions ------------------------------------------------------------------

data TypeError = TypeError Text
 deriving (Eq, Ord, Show, Exception)

data Crash = Crash Val
 deriving (Eq, Ord, Show, Exception)

data BadRef = BadRef Jet Int
 deriving (Eq, Ord, Show, Exception)


--------------------------------------------------------------------------------

{- |
    If a function is oversaturated, call it (with too many arguments,
    it's fine), and then call the result with the remaining arguments.
-}
execFun :: Fun -> IO Val
{-# INLINE execFun #-}
execFun f@Fun {..} = compare fNeed 0 & \case
  GT -> pure (VFun f)
  EQ -> callNodeFull fHead fArgs
  LT -> do
    f         <- callNodeFull fHead fArgs
    extraArgs <- arrayDrop (sizeofArray fArgs) (negate fNeed) fArgs
    callVal f extraArgs

arrayDrop :: Int -> Int -> Array Val -> IO (Array Val)
{-# INLINE arrayDrop #-}
arrayDrop i l xs = thawArray xs i l >>= unsafeFreezeArray

callNodeFull :: Node -> Array Val -> IO Val
{-# INLINE callNodeFull #-}
callNodeFull !no !xs = no & \case
  Kay   -> pure x
  Dee   -> pure $ jam x
  Ess   -> join (c2 x z <$> c1 y z)
  Jay _ -> error "TODO"
  _     -> error "TODO"
 where
  x = v 0
  y = v 1
  z = v 2
  v = indexArray xs

c1 = callVal1
c2 = callVal2

callVal1 f x = callVal f (fromList [x])
callVal2 f x y = callVal f (fromList [x, y])

callFunFull :: Fun -> Array Val -> IO Val
{-# INLINE callFunFull #-}
callFunFull Fun {..} xs = callNodeFull fHead (fArgs <> xs)

valFun :: Val -> Fun
{-# INLINE valFun #-}
valFun = \case
  VUni     -> Fun 1 Uni mempty
  VCon h t -> Fun 1 Con (fromList [h, t])
  VLef l   -> Fun 2 Lef (fromList [l])
  VRit r   -> Fun 2 Lef (fromList [r])
  VNat n   -> Fun 2 (Nat n) mempty
  VBol b   -> Fun 2 (Bol b) mempty
  VFun f   -> f


-- Jet Invokation --------------------------------------------------------------

emptyRegisterSet :: IOArray Val
emptyRegisterSet = unsafePerformIO (newArray 0 VUni)

mkRegs :: Int -> IO (IOArray Val)
{-# INLINE mkRegs #-}
mkRegs 0 = pure emptyRegisterSet
mkRegs n = newArray n VUni

withFallback :: Jet -> Array Val -> IO Val -> IO Val
{-# INLINE withFallback #-}
withFallback j args act = catch act $ \(TypeError why) -> do
  putStrLn ("FALLBACK: " <> why)
  callFunFull (valFun $ jBody j) args

execJet1 :: Jet -> Val -> IO Val
execJet1 !j !x = do
  regs <- mkRegs (jRegs j)
  withFallback j args $ execJetBody j ref (readArray regs) (writeArray regs)
 where
  ref 0 = pure x
  ref n = throwIO (BadRef j n)
  args = fromList [x]

execJet2 :: Jet -> Val -> Val -> IO Val
execJet2 !j !x !y = do
  regs <- mkRegs (jRegs j)
  withFallback j args $ execJetBody j ref (readArray regs) (writeArray regs)
 where
  ref 0 = pure x
  ref 1 = pure y
  ref n = throwIO (BadRef j n)
  args = fromList [x, y]

execJet3 :: Jet -> Val -> Val -> Val -> IO Val
execJet3 !j !x !y !z = do
  regs <- mkRegs (jRegs j)
  withFallback j args $ execJetBody j ref (readArray regs) (writeArray regs)
 where
  ref 0 = pure x
  ref 1 = pure y
  ref 2 = pure z
  ref n = throwIO (BadRef j n)
  args = fromList [x, y, z]

execJet4 :: Jet -> Val -> Val -> Val -> Val -> IO Val
execJet4 !j !x !y !z !p = do
  regs <- mkRegs (jRegs j)
  withFallback j args $ execJetBody j ref (readArray regs) (writeArray regs)
 where
  ref 0 = pure x
  ref 1 = pure y
  ref 2 = pure z
  ref 3 = pure p
  ref n = throwIO (BadRef j n)
  args = fromList [x, y, z, p]

execJetN :: Jet -> Array Val -> IO Val
execJetN !j !xs = do
  regs <- mkRegs (jRegs j)
  withFallback j xs $ execJetBody j ref (readArray regs) (writeArray regs)
  where ref i = pure (indexArray xs i)


-- Primitive Implementation ----------------------------------------------------

inc :: Val -> IO Val
{-# INLINE inc #-}
inc (VNat x) = pure $ VNat (x + 1)
inc _        = throwIO (TypeError "inc-not-nat")

dec :: Val -> IO Val
{-# INLINE dec #-}
dec (VNat 0) = pure $ VLef VUni
dec (VNat n) = pure $ VRit (VNat (n - 1))
dec _        = throwIO (TypeError "dec-not-nat")

fec :: Val -> IO Val
{-# INLINE fec #-}
fec (VNat 0) = pure (VNat 0)
fec (VNat n) = pure (VNat (n - 1))
fec _        = throwIO (TypeError "fec-not-nat")

add :: Val -> Val -> IO Val
{-# INLINE add #-}
add (VNat x) (VNat y) = pure (VNat (x + y))
add _        _        = throwIO (TypeError "add-not-nat")

mul :: Val -> Val -> IO Val
{-# INLINE mul #-}
mul (VNat x) (VNat y) = pure (VNat (x * y))
mul _        _        = throwIO (TypeError "mul-not-nat")

sub :: Val -> Val -> IO Val
{-# INLINE sub #-}
sub (VNat x) (VNat y) | y > x = pure (VLef VUni)
sub (VNat x) (VNat y)         = pure (VRit (VNat (x - y)))
sub _        _                = throwIO (TypeError "sub-not-nat")

zer :: Val -> IO Val
{-# INLINE zer #-}
zer (VNat 0) = pure (VBol True)
zer (VNat n) = pure (VBol False)
zer v        = throwIO (TypeError ("zer-not-nat: " <> tshow v))

eql :: Val -> Val -> IO Val
{-# INLINE eql #-}
eql (VNat x) (VNat y) = pure (VBol (x == y))
eql _        _        = throwIO (TypeError "eql-not-nat")

car :: Val -> IO Val
{-# INLINE car #-}
car (VCon x _) = pure x
car _          = throwIO (TypeError "car-not-con")

cdr :: Val -> IO Val
{-# INLINE cdr #-}
cdr (VCon _ y) = pure y
cdr _          = throwIO (TypeError "cdr-not-con")

-- Interpreter -----------------------------------------------------------------

cloN :: Fun -> Array Val -> Val
{-# INLINE cloN #-}
cloN (Fun {..}) xs = VFun $ Fun rem fHead $ fArgs <> xs
  where rem = fNeed - sizeofArray xs

callVal :: Val -> Array Val -> IO Val
{-# INLINE callVal #-}
callVal f xs =
  let Fun {..} = valFun f
  in  execFun (Fun (fNeed - sizeofArray xs) fHead (fArgs <> xs))

jetVal :: Jet -> Val
{-# INLINE jetVal #-}
jetVal j = VFun $ Fun (jArgs j) (Jut j) mempty

execJetBody
  :: Jet
  -> (Int -> IO Val)
  -> (Int -> IO Val)
  -> (Int -> Val -> IO ())
  -> IO Val
{-# INLINE execJetBody #-}
execJetBody !j !ref !reg !setReg = go (jFast j)
 where
  go :: Exp -> IO Val
  go = \case
    VAL  v         -> pure v
    REF  i         -> ref i
    REC1 x         -> join (execJet1 j <$> go x)
    REC2 x y       -> join (execJet2 j <$> go x <*> go y)
    REC3 x y z     -> join (execJet3 j <$> go x <*> go y <*> go z)
    REC4 x y z p   -> join (execJet4 j <$> go x <*> go y <*> go z <*> go p)
    RECN xs        -> join (execJetN j <$> traverse go xs)
    SLF            -> pure (jetVal j)
    SEQ x y        -> go x >> go y
    DED x          -> throwIO . Crash =<< go x
    INC x          -> join (inc <$> go x)
    DEC x          -> join (dec <$> go x)
    FEC x          -> join (fec <$> go x)
    LEF x          -> VLef <$> go x
    RIT x          -> VRit <$> go x
    JET1 j x       -> join (execJet1 j <$> go x)
    JET2 j x y     -> join (execJet2 j <$> go x <*> go y)
    JET3 j x y z   -> join (execJet3 j <$> go x <*> go y <*> go z)
    JET4 j x y z p -> join (execJet4 j <$> go x <*> go y <*> go z <*> go p)
    JETN j xs      -> join (execJetN j <$> traverse go xs)
    ADD  x y       -> join (add <$> go x <*> go y)
    MUL  x y       -> join (mul <$> go x <*> go y)
    SUB  x y       -> join (sub <$> go x <*> go y)
    ZER x          -> join (zer <$> go x)
    EQL x y        -> join (eql <$> go x <*> go y)
    CON x y        -> VCon <$> go x <*> go y
    CAR x          -> join (car <$> go x)
    CDR x          -> join (cdr <$> go x)
    CLON f xs      -> cloN f <$> traverse go xs
    CALN f xs      -> join (callVal <$> go f <*> traverse go xs)

    IFF c t e -> go c >>= \case
      VBol True  -> go t
      VBol False -> go e
      _          -> throwIO (TypeError "iff-not-bol")

    CAS i x l r -> go x >>= \case
      VLef lv -> setReg i lv >> go l
      VRit rv -> setReg i rv >> go r
      _       -> throwIO (TypeError "cas-no-sum")
