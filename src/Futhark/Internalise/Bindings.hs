{-# LANGUAGE FlexibleContexts #-}
module Futhark.Internalise.Bindings
  (
  -- * Internalising bindings
    bindingParams
  , bindingLambdaParams

  , flattenPattern
  , bindingPattern
  , bindingFlatPattern
  )
  where

import Control.Applicative
import Control.Monad.State  hiding (mapM)
import Control.Monad.Reader hiding (mapM)
import Control.Monad.Writer hiding (mapM)

import qualified Data.HashMap.Lazy as HM
import Data.List
import Data.Traversable (mapM)

import Language.Futhark as E
import qualified Futhark.Representation.SOACS as I
import Futhark.MonadFreshNames

import Futhark.Internalise.Monad
import Futhark.Internalise.TypesValues

import Prelude hiding (mapM)

internaliseBindee :: MonadFreshNames m =>
                     E.Ident
                  -> m [(VName, I.DeclExtType)]
internaliseBindee bindee =
  forM (internaliseTypeWithUniqueness $ E.unInfo $ E.identType bindee) $ \t -> do
    name <- newVName base
    return (name, t)
  where base = nameToString $ baseName $ E.identName bindee

bindingParams :: [E.Pattern]
              -> ([I.FParam] -> [I.FParam] -> InternaliseM a)
              -> InternaliseM a
bindingParams params m = do
  params_idents <- concat <$> mapM flattenPattern params
  (param_ts, shape_ctx) <- internaliseParamTypes $ map patternStructType params
  (shape_ctx', shapesubst) <- makeShapeIdentsFromContext shape_ctx

  (param_ts', unnamed_shape_params) <- instantiateShapesWithDecls shape_ctx' $ concat param_ts
  let named_shape_params = map nonuniqueParamFromIdent (HM.elems shape_ctx')
      shape_params = named_shape_params ++ unnamed_shape_params
  bindingFlatPattern params_idents param_ts' $ \valueparams ->
    bindingIdentTypes (map I.paramIdent $ shape_params++valueparams) $
    local (\env -> env { envSubsts = shapesubst `HM.union` envSubsts env}) $
    m shape_params valueparams

bindingLambdaParams :: [E.Pattern] -> [I.Type]
                    -> ([I.LParam] -> InternaliseM a)
                    -> InternaliseM a
bindingLambdaParams params ts m = do
  params_idents <- concat <$> mapM flattenPattern params
  (param_ts, shape_ctx) <- internaliseParamTypes $ map patternStructType params
  bindingFlatPattern params_idents ts $ \params' ->
    local (\env -> env { envSubsts =
                           envSubsts env <>
                           lambdaShapeSubstitutions shape_ctx (concat param_ts) ts }) $
    bindingIdentTypes (map I.paramIdent params') $ m params'

processFlatPattern :: [E.Ident] -> [t]
                   -> InternaliseM ([I.Param t], VarSubstitutions)
processFlatPattern = processFlatPattern' []
  where
    processFlatPattern' pat []       _  = do
      let (vs, substs) = unzip pat
          substs' = HM.fromList substs
          idents = concat $ reverse vs
      return (idents, substs')

    processFlatPattern' pat (p:rest) ts = do
      (ps, subst, rest_ts) <- handleMapping ts <$> internaliseBindee p
      processFlatPattern' ((ps, (E.identName p, map (I.Var . I.paramName) subst)) : pat) rest rest_ts

    handleMapping ts [] =
      ([], [], ts)
    handleMapping ts (r:rs) =
        let (ps, reps, ts')    = handleMapping' ts r
            (pss, repss, ts'') = handleMapping ts' rs
        in (ps++pss, reps:repss, ts'')

    handleMapping' (t:ts) (vname,_) =
      let v' = I.Param vname t
      in ([v'], v', ts)
    handleMapping' [] _ =
      error "processFlatPattern: insufficient identifiers in pattern."

bindingFlatPattern :: [E.Ident] -> [t]
                   -> ([I.Param t] -> InternaliseM a)
                   -> InternaliseM a
bindingFlatPattern idents ts m = do
  (ps, substs) <- processFlatPattern idents ts
  local (\env -> env { envSubsts = substs `HM.union` envSubsts env}) $
    m ps

flattenPattern :: MonadFreshNames m => E.Pattern -> m [E.Ident]
flattenPattern (E.Wildcard t loc) = do
  name <- newVName "nameless"
  return [E.Ident name t loc]
flattenPattern (E.Id v) =
  return [v]
flattenPattern (E.TuplePattern pats _) =
  concat <$> mapM flattenPattern pats
flattenPattern (E.PatternAscription p _) =
  flattenPattern p

bindingPattern :: E.Pattern -> [I.ExtType] -> (I.Pattern -> InternaliseM a)
                -> InternaliseM a
bindingPattern pat ts m = do
  pat' <- flattenPattern pat
  (ts',shapes) <- instantiateShapes' ts
  let addShapeStms = m . I.basicPattern' shapes . map I.paramIdent
  bindingFlatPattern pat' ts' addShapeStms

makeShapeIdentsFromContext :: MonadFreshNames m =>
                              HM.HashMap VName Int
                           -> m (HM.HashMap Int I.Ident,
                                 VarSubstitutions)
makeShapeIdentsFromContext ctx = do
  (ctx', substs) <- fmap unzip $ forM (HM.toList ctx) $ \(name, i) -> do
    v <- newIdent (baseString name) $ I.Prim I.int32
    return ((i, v), (name, [I.Var $ I.identName v]))
  return (HM.fromList ctx', HM.fromList substs)

instantiateShapesWithDecls :: MonadFreshNames m =>
                              HM.HashMap Int I.Ident
                           -> [I.DeclExtType]
                           -> m ([I.DeclType], [I.FParam])
instantiateShapesWithDecls ctx ts =
  runWriterT $ instantiateShapes instantiate ts
  where instantiate x
          | Just v <- HM.lookup x ctx =
            return $ I.Var $ I.identName v

          | otherwise = do
            v <- lift $ nonuniqueParamFromIdent <$> newIdent "size" (I.Prim I.int32)
            tell [v]
            return $ I.Var $ I.paramName v

lambdaShapeSubstitutions :: HM.HashMap VName Int
                         -> [I.TypeBase I.ExtShape Uniqueness]
                         -> [I.Type]
                         -> VarSubstitutions
lambdaShapeSubstitutions shape_ctx param_ts ts =
  mconcat $ zipWith matchTypes param_ts ts
  where ctx_to_names = HM.fromList $ map (uncurry $ flip (,)) $ HM.toList shape_ctx

        matchTypes pt t =
          mconcat $ zipWith matchDims (I.extShapeDims $ I.arrayShape pt) (I.arrayDims t)
        matchDims (I.Ext i) d
          | Just v <- HM.lookup i ctx_to_names = HM.singleton v [d]
        matchDims _ _ =
          mempty

nonuniqueParamFromIdent :: I.Ident -> I.FParam
nonuniqueParamFromIdent (I.Ident name t) =
  I.Param name $ I.toDecl t Nonunique
