{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The value representation used in the interpreter.
--
-- Kept simple and free of unnecessary operational details (in
-- particular, no references to the interpreter monad).
module Language.Futhark.Interpreter.Values
  ( -- * Shapes
    Shape (..),
    ValueShape,
    typeShape,
    structTypeShape,

    -- * Values
    Value (..),
    valueShape,
    prettyValue,
    valueText,
    fromTuple,
    arrayLength,
    isEmptyArray,
    prettyEmptyArray,
    toArray,
    toArray',
    toTuple,

    -- * Conversion
    fromDataValue,
  )
where

import Data.Array
import Data.List (genericLength)
import qualified Data.Map as M
import Data.Maybe
import Data.Monoid hiding (Sum)
import qualified Data.Text as T
import qualified Data.Vector.Storable as SVec
import qualified Futhark.Data as V
import Futhark.Util (chunk)
import Futhark.Util.Pretty
import Language.Futhark hiding (Shape, matchDims)
import qualified Language.Futhark.Primitive as P
import Prelude hiding (break, mod)

prettyRecord :: (a -> Doc ann) -> M.Map Name a -> Doc ann
prettyRecord p m
  | Just vs <- areTupleFields m =
      parens $ commasep $ map p vs
  | otherwise =
      braces $ commasep $ map field $ M.toList m
  where
    field (k, v) = pretty k <+> equals <+> p v

-- | A shape is a tree to accomodate the case of records.  It is
-- parameterised over the representation of dimensions.
data Shape d
  = ShapeDim d (Shape d)
  | ShapeLeaf
  | ShapeRecord (M.Map Name (Shape d))
  | ShapeSum (M.Map Name [Shape d])
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | The shape of an array.
type ValueShape = Shape Int64

instance Pretty d => Pretty (Shape d) where
  pretty ShapeLeaf = mempty
  pretty (ShapeDim d s) = brackets (pretty d) <> pretty s
  pretty (ShapeRecord m) = prettyRecord pretty m
  pretty (ShapeSum cs) =
    mconcat (punctuate " | " cs')
    where
      ppConstr (name, fs) = sep $ ("#" <> pretty name) : map pretty fs
      cs' = map ppConstr $ M.toList cs

emptyShape :: ValueShape -> Bool
emptyShape (ShapeDim d s) = d == 0 || emptyShape s
emptyShape _ = False

typeShape :: M.Map VName (Shape d) -> TypeBase d () -> Shape d
typeShape shapes = go
  where
    go (Array _ _ shape et) =
      foldr ShapeDim (go (Scalar et)) $ shapeDims shape
    go (Scalar (Record fs)) =
      ShapeRecord $ M.map go fs
    go (Scalar (Sum cs)) =
      ShapeSum $ M.map (map go) cs
    go (Scalar (TypeVar _ _ (QualName [] v) []))
      | Just shape <- M.lookup v shapes =
          shape
    go _ =
      ShapeLeaf

structTypeShape :: M.Map VName ValueShape -> StructType -> Shape (Maybe Int64)
structTypeShape shapes = fmap dim . typeShape shapes'
  where
    dim (ConstSize d) = Just $ fromIntegral d
    dim _ = Nothing
    shapes' = M.map (fmap $ ConstSize . fromIntegral) shapes

-- | A fully evaluated Futhark value.
data Value m
  = ValuePrim !PrimValue
  | ValueArray ValueShape !(Array Int (Value m))
  | -- Stores the full shape.
    ValueRecord (M.Map Name (Value m))
  | ValueFun (Value m -> m (Value m))
  | -- Stores the full shape.
    ValueSum ValueShape Name [Value m]
  | -- The update function and the array.
    ValueAcc (Value m -> Value m -> m (Value m)) !(Array Int (Value m))

instance Show (Value m) where
  show (ValuePrim v) = "ValuePrim " <> show v <> ""
  show (ValueArray shape vs) = unwords ["ValueArray", show shape, show vs]
  show (ValueRecord fs) = "ValueRecord " <> show fs
  show (ValueSum shape c vs) = unwords ["ValueSum", show shape, show c, show vs]
  show ValueFun {} = "ValueFun _"
  show ValueAcc {} = "ValueAcc _"

instance Eq (Value m) where
  ValuePrim (SignedValue x) == ValuePrim (SignedValue y) =
    P.doCmpEq (P.IntValue x) (P.IntValue y)
  ValuePrim (UnsignedValue x) == ValuePrim (UnsignedValue y) =
    P.doCmpEq (P.IntValue x) (P.IntValue y)
  ValuePrim (FloatValue x) == ValuePrim (FloatValue y) =
    P.doCmpEq (P.FloatValue x) (P.FloatValue y)
  ValuePrim (BoolValue x) == ValuePrim (BoolValue y) =
    P.doCmpEq (P.BoolValue x) (P.BoolValue y)
  ValueArray _ x == ValueArray _ y = x == y
  ValueRecord x == ValueRecord y = x == y
  ValueSum _ n1 vs1 == ValueSum _ n2 vs2 = n1 == n2 && vs1 == vs2
  ValueAcc _ x == ValueAcc _ y = x == y
  _ == _ = False

prettyValueWith :: (PrimValue -> Doc a) -> Value m -> Doc a
prettyValueWith pprPrim = pprPrec (0 :: Int)
  where
    pprPrec _ (ValuePrim v) = pprPrim v
    pprPrec _ (ValueArray _ a) =
      let elements = elems a -- [Value]
          separator = case elements of
            ValueArray _ _ : _ -> comma <> line
            _ -> comma <> space
       in brackets $ align $ fillSep $ punctuate separator (map (pprPrec 0) elements)
    pprPrec _ (ValueRecord m) = prettyRecord (pprPrec 0) m
    pprPrec _ ValueFun {} = "#<fun>"
    pprPrec _ ValueAcc {} = "#<acc>"
    pprPrec p (ValueSum _ n vs) =
      parensIf (p > 0) $ "#" <> sep (pretty n : map (pprPrec 1) vs)

-- | Prettyprint value.
prettyValue :: Value m -> Doc a
prettyValue = prettyValueWith pprPrim
  where
    pprPrim (UnsignedValue (Int8Value v)) = pretty v
    pprPrim (UnsignedValue (Int16Value v)) = pretty v
    pprPrim (UnsignedValue (Int32Value v)) = pretty v
    pprPrim (UnsignedValue (Int64Value v)) = pretty v
    pprPrim (SignedValue (Int8Value v)) = pretty v
    pprPrim (SignedValue (Int16Value v)) = pretty v
    pprPrim (SignedValue (Int32Value v)) = pretty v
    pprPrim (SignedValue (Int64Value v)) = pretty v
    pprPrim (BoolValue True) = "true"
    pprPrim (BoolValue False) = "false"
    pprPrim (FloatValue v) = pretty v

-- | The value in the textual format.
valueText :: Value m -> T.Text
valueText = docText . prettyValueWith pretty

valueShape :: Value m -> ValueShape
valueShape (ValueArray shape _) = shape
valueShape (ValueRecord fs) = ShapeRecord $ M.map valueShape fs
valueShape (ValueSum shape _ _) = shape
valueShape _ = ShapeLeaf

-- | Does the value correspond to an empty array?
isEmptyArray :: Value m -> Bool
isEmptyArray = emptyShape . valueShape

-- | String representation of an empty array with the provided element
-- type.  This is pretty ad-hoc - don't expect good results unless the
-- element type is a primitive.
prettyEmptyArray :: TypeBase () () -> Value m -> T.Text
prettyEmptyArray t v =
  "empty(" <> dims (valueShape v) <> prettyText t' <> ")"
  where
    t' = stripArray (arrayRank t) t
    dims (ShapeDim n rowshape) =
      "[" <> prettyText n <> "]" <> dims rowshape
    dims _ = ""

toArray :: ValueShape -> [Value m] -> Value m
toArray shape vs = ValueArray shape (listArray (0, length vs - 1) vs)

toArray' :: ValueShape -> [Value m] -> Value m
toArray' rowshape vs = ValueArray shape (listArray (0, length vs - 1) vs)
  where
    shape = ShapeDim (genericLength vs) rowshape

arrayLength :: Integral int => Array Int (Value m) -> int
arrayLength = fromIntegral . (+ 1) . snd . bounds

toTuple :: [Value m] -> Value m
toTuple = ValueRecord . M.fromList . zip tupleFieldNames

fromTuple :: Value m -> Maybe [Value m]
fromTuple (ValueRecord m) = areTupleFields m
fromTuple _ = Nothing

fromDataShape :: V.Vector Int -> ValueShape
fromDataShape = foldr (ShapeDim . fromIntegral) ShapeLeaf . SVec.toList

fromDataValueWith ::
  SVec.Storable a =>
  (a -> PrimValue) ->
  SVec.Vector Int ->
  SVec.Vector a ->
  Value m
fromDataValueWith f shape vector =
  if SVec.null shape
    then ValuePrim $ f $ SVec.head vector
    else
      toArray (fromDataShape shape)
        . map (fromDataValueWith f shape' . SVec.fromList)
        $ chunk (SVec.product shape') (SVec.toList vector)
  where
    shape' = SVec.tail shape

-- | Convert a Futhark value in the externally observable data format
-- to an interpreter value.
fromDataValue :: V.Value -> Value m
fromDataValue (V.I8Value shape vector) =
  fromDataValueWith (SignedValue . Int8Value) shape vector
fromDataValue (V.I16Value shape vector) =
  fromDataValueWith (SignedValue . Int16Value) shape vector
fromDataValue (V.I32Value shape vector) =
  fromDataValueWith (SignedValue . Int32Value) shape vector
fromDataValue (V.I64Value shape vector) =
  fromDataValueWith (SignedValue . Int64Value) shape vector
fromDataValue (V.U8Value shape vector) =
  fromDataValueWith (UnsignedValue . Int8Value . fromIntegral) shape vector
fromDataValue (V.U16Value shape vector) =
  fromDataValueWith (UnsignedValue . Int16Value . fromIntegral) shape vector
fromDataValue (V.U32Value shape vector) =
  fromDataValueWith (UnsignedValue . Int32Value . fromIntegral) shape vector
fromDataValue (V.U64Value shape vector) =
  fromDataValueWith (UnsignedValue . Int64Value . fromIntegral) shape vector
fromDataValue (V.F16Value shape vector) =
  fromDataValueWith (FloatValue . Float16Value) shape vector
fromDataValue (V.F32Value shape vector) =
  fromDataValueWith (FloatValue . Float32Value) shape vector
fromDataValue (V.F64Value shape vector) =
  fromDataValueWith (FloatValue . Float64Value) shape vector
fromDataValue (V.BoolValue shape vector) =
  fromDataValueWith BoolValue shape vector