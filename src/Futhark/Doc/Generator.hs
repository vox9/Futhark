{-# LANGUAGE OverloadedStrings #-}
module Futhark.Doc.Generator (renderFile, indexPage) where

import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Data.List (sort)
import Data.Monoid
import Data.Maybe (maybe,mapMaybe)
import qualified Data.Map as M
import System.FilePath (splitPath, (-<.>), makeRelative)
import Text.Blaze.Html5 as H hiding (text, map, main)
import qualified Text.Blaze.Html5.Attributes as A
import Data.String (fromString)
import Data.Version

import Prelude hiding (head, div)

import Language.Futhark.TypeChecker (FileModule(..))
import Language.Futhark.TypeChecker.Monad
import Language.Futhark
import Futhark.Doc.Html
import Futhark.Version

type Context = (String,FileModule)
type DocEnv = M.Map (Namespace,VName) String
type DocM = ReaderT Context (State DocEnv)

renderFile :: [Dec] -> DocM Html
renderFile ds = do
  current <- asks fst
  moduleBoilerplate current <$> renderDecs ds

indexPage :: [(String, String)] -> Html
indexPage pages = docTypeHtml $ addBoilerplate "/" "Futhark Library Documentation" $
                  ul (mconcat $ map linkTo $ sort pages)
  where linkTo (name, _) =
          let file = makeRelative "/" $ name -<.> "html"
          in li $ a ! A.href (fromString file) $ fromString name

addBoilerplate :: String -> String -> Html -> Html
addBoilerplate current titleText bodyHtml =
  let headHtml = head $
                 title (fromString titleText) <>
                 link ! A.href (fromString $ relativise "style.css" current)
                      ! A.rel "stylesheet"
                      ! A.type_ "text/css"
      madeByHtml =
        H.div ! A.id "footer" $ hr
        <> "Generated by " <> (a ! A.href futhark_doc_url) "futhark-doc"
        <> " " <> fromString (showVersion version)
  in headHtml <> body (h1 (toHtml titleText) <> bodyHtml <> madeByHtml)
  where futhark_doc_url =
          "https://futhark.readthedocs.io/en/latest/man/futhark-doc.html"

moduleBoilerplate :: String -> Html -> Html
moduleBoilerplate current bodyHtml =
  addBoilerplate current current ((H.div ! A.class_ "module") bodyHtml)

renderDecs :: [Dec] -> DocM Html
renderDecs decs = asks snd >>= f
  where f fm = H.div ! A.class_ "decs" <$> mconcat <$>
               mapM (fmap $ H.div ! A.class_ "dec") (mapMaybe (prettyDec fm) decs)

prettyDec :: FileModule -> Dec -> Maybe (DocM Html)
prettyDec fileModule dec = case dec of
  FunDec f -> return <$> prettyFun fileModule f
  SigDec s -> prettySig fileModule s
  ModDec m -> prettyMod fileModule m
  ValDec v -> prettyVal fileModule v
  TypeDec t -> renderType fileModule t
  OpenDec _x _xs (Info _names) _ -> Nothing
                            --Just $ prettyOpen fileModule (x:xs) names
  LocalDec _ _ -> Nothing

--prettyOpen :: FileModule -> [ModExpBase Info VName] -> [VName] -> DocM Html
--prettyOpen fm xs (Info names) = mconcat <$> mapM (renderModExp fm) xs
--  where FileModule (Env { envModTable = modtable }) = fm
    --envs = foldMap (renderEnv . (\(ModEnv e) -> e) . (modtable M.!)) names

prettyFun :: FileModule -> FunBindBase t VName -> Maybe Html
prettyFun fm (FunBind _ name _retdecl _rettype _tparams _args _ doc _)
  | Just (BoundF (tps,pts,rett)) <- M.lookup name vtable
  , visible Term name fm = Just $
    renderDoc doc <> "val " <> vnameHtml name <>
    foldMap (" " <>) (map prettyTypeParam tps) <> ": " <>
    foldMap (\t -> prettyParam t <> " -> ") pts <> prettyType rett
    where FileModule Env {envVtable = vtable} _ = fm
prettyFun _ _ = Nothing

prettyVal :: FileModule -> ValBindBase Info VName -> Maybe (DocM Html)
prettyVal fm (ValBind _entry name maybe_t _ _e doc _)
  | Just (BoundV st) <- M.lookup name vtable
  , visible Term name fm =
    Just . return . H.div $
    renderDoc doc <> "let " <> vnameHtml name <> " : " <>
    maybe (prettyType st) typeExpHtml maybe_t
    where (FileModule Env {envVtable = vtable} _) = fm
prettyVal _ _ = Nothing

prettySig :: FileModule -> SigBindBase Info VName -> Maybe (DocM Html)
prettySig fm (SigBind vname se doc _)
  | M.member vname sigtable && visible Signature vname fm =
    Just $ H.div <$> do
      name <- vnameHtmlM Signature vname
      expHtml <- renderSigExp se
      return $ renderDoc doc <> "module type " <> name <>
        " = " <> expHtml
    where (FileModule Env { envSigTable = sigtable } _) = fm
prettySig _ _ = Nothing

prettyMod :: FileModule -> ModBindBase Info VName -> Maybe (DocM Html)
prettyMod fm (ModBind name ps sig _me doc _)
  | Just env <- M.lookup name modtable
  , visible Structure name fm = Just $ div ! A.class_ "mod" <$> do
    vname <- vnameHtmlM Structure name
    params <- modParamHtml ps
    s <- case sig of Nothing -> envSig env
                     Just (s,_) -> renderSigExp s
    return $ renderDoc doc <> "module " <> vname <> ": " <> params <> s
    where FileModule Env { envModTable = modtable} _ = fm
          envSig (ModEnv e) = renderEnv e
          envSig (ModFun (FunSig _ _ (MTy _ m))) = envSig m
prettyMod _ _ = Nothing

renderType :: FileModule -> TypeBindBase Info VName -> Maybe (DocM Html)
renderType fm tb
  | M.member name typeTable
  , visible Type name fm = Just $ H.div <$> typeBindHtml tb
    where (FileModule Env {envTypeTable = typeTable} _) = fm
          TypeBind { typeAlias = name } = tb
renderType _ _ = Nothing

_ = let
  renderModExp :: FileModule -> ModExpBase Info VName -> DocM Html
  renderModExp fm e = case e of
    ModVar v _ -> renderQualName Structure v
    ModParens e' _ -> parens <$> renderModExp fm e'
    ModImport v _ -> return $ toHtml $ show v
    ModDecs ds _ ->
      renderDecs ds --nestedBlock "{" "}" (stack $ punctuate line $ map ppr ds)
    ModApply _f _a _ _ _ -> return mempty --parens $ ppr f <+> parens (ppr a)
    ModAscript _me se _ _ -> ("{...}: " <>) <$> renderSigExp se
    --ppr me <> colon <+> ppr se
    ModLambda _param _maybe_sig _body _ ->
      error "It should not be possible to open a lambda"
  in renderModExp

visible :: Namespace -> VName -> FileModule -> Bool
visible ns vname@(VName name _) (FileModule env _)
  | Just vname' <- M.lookup (ns,name) (envNameMap env)
  = vname == vname'
visible _ _ _ = False

renderDoc :: Maybe String -> Html
renderDoc (Just doc) =
  H.div ! A.class_ "comment" $ toHtml $ comments $ lines doc
  where comments [] = ""
        comments (x:xs) = unlines $ ("-- | " ++ x) : map ("--"++) xs
renderDoc Nothing = mempty

renderEnv :: Env -> DocM Html
renderEnv (Env vtable ttable sigtable modtable _) =
  return $ braces (mconcat specs)
  where specs = typeBinds ++ valBinds ++ sigBinds ++ modBinds
        typeBinds = map renderTypeBind (M.toList ttable)
        valBinds = map renderValBind (M.toList vtable)
        sigBinds = map renderModType (M.toList sigtable)
        modBinds = map renderMod (M.toList modtable)

renderModType :: (VName, MTy) -> Html
renderModType (name, _sig) =
  "module type " <> vnameHtml name

renderMod :: (VName, Mod) -> Html
renderMod (name, _mod) =
  "module " <> vnameHtml name

renderValBind :: (VName, ValBinding) -> Html
renderValBind = H.div . prettyValBind

renderTypeBind :: (VName, TypeBinding) -> Html
renderTypeBind (name, TypeAbbr tps tp) =
  H.div $ typeHtml name tps <> prettyType tp

prettyValBind :: (VName, ValBinding) -> Html
prettyValBind (name, BoundF (tps, pts, rettype)) =
  "val " <> vnameHtml name <>
  foldMap (" " <>) (map prettyTypeParam tps) <> ": " <>
  foldMap (\t -> prettyParam t <> " -> ") pts <> " " <>
  prettyType rettype
prettyValBind (name, BoundV t) =
  "val " <> vnameHtml name <> " : " <> prettyType t

prettyParam :: (Maybe VName, StructType) -> Html
prettyParam (Nothing, t) = prettyType t
prettyParam (Just v, t) = parens $ vnameHtml v <> ": " <> prettyType t

prettyType :: StructType -> Html
prettyType t = case t of
  Prim et -> primTypeHtml et
  Record fs
    | Just ts <- areTupleFields fs ->
        parens $ commas (map prettyType ts)
    | otherwise ->
        braces $ commas (map ppField $ M.toList fs)
    where ppField (name, tp) =
            toHtml (nameToString name) <> ":" <> prettyType tp
  TypeVar et targs ->
    prettyTypeName et <> foldMap ((<> " ") . prettyTypeArg) targs
  Array arr -> prettyArray arr

prettyArray :: ArrayTypeBase (DimDecl VName) () -> Html
prettyArray arr = case arr of
  PrimArray et (ShapeDecl ds) u _ ->
    prettyU u <> foldMap (brackets . prettyD) ds <> primTypeHtml et
  PolyArray et targs shape u _ ->
    prettyU u <> prettyShapeDecl shape <> prettyTypeName et <>
    foldMap (<> " ") (map prettyTypeArg targs)
  RecordArray fs shape u
    | Just ts <- areTupleFields fs ->
        prefix <> parens (commas $ map prettyElem ts)
    | otherwise ->
        prefix <> braces (commas $ map ppField $ M.toList fs)
    where prefix = prettyU u <> prettyShapeDecl shape
          ppField (name, tp) = toHtml (nameToString name) <>
                               ":" <> prettyElem tp

prettyElem :: RecordArrayElemTypeBase (DimDecl VName) () -> Html
prettyElem e = case e of
  PrimArrayElem bt _ u -> prettyU u <> primTypeHtml bt
  PolyArrayElem bt targs _ u ->
    prettyU u <> prettyTypeName  bt <> foldMap (" " <>)
    (map prettyTypeArg targs)
  ArrayArrayElem at -> prettyArray at
  RecordArrayElem fs
    | Just ts <- areTupleFields fs
      -> parens $ commas $ map prettyElem ts
    | otherwise
      -> braces . commas $ map ppField $ M.toList fs
    where ppField (name, t) = toHtml (nameToString name) <>
            ":" <> prettyElem t

prettyShapeDecl :: ShapeDecl (DimDecl VName) -> Html
prettyShapeDecl (ShapeDecl ds) =
  foldMap (brackets . prettyDimDecl) ds

prettyTypeArg :: TypeArg (DimDecl VName) () -> Html
prettyTypeArg (TypeArgDim d _) = brackets $ prettyDimDecl d
prettyTypeArg (TypeArgType t _) = prettyType t

modParamHtml :: [ModParamBase Info VName] -> DocM Html
modParamHtml [] = return mempty
modParamHtml (ModParam pname psig _ : mps) =
  liftM2 f (renderSigExp psig) (modParamHtml mps)
  where f se params = "(" <> vnameHtml pname <>
                      ": " <> se <> ") -> " <> params

prettyD :: DimDecl VName -> Html
prettyD (NamedDim v) = prettyQualName v
prettyD (ConstDim _) = mempty
prettyD AnyDim = mempty

renderSigExp :: SigExpBase Info VName -> DocM Html
renderSigExp e = case e of
  SigVar v _ -> renderQualName Signature v
  SigParens e' _ -> parens <$> renderSigExp e'
  SigSpecs ss _ -> braces . (div ! A.class_ "specs") . mconcat <$> mapM specHtml ss
  SigWith s (TypeRef v t) _ ->
    do e' <- renderSigExp s
       --name <- renderQualName Type v
       return $ e' <> " with " <> prettyQualName v <>
         " = "  <> typeDeclHtml t
  SigArrow Nothing e1 e2 _ ->
    liftM2 f (renderSigExp e1) (renderSigExp e2)
    where f e1' e2' = e1' <> " -> " <> e2'
  SigArrow (Just v) e1 e2 _ ->
    do name <- vnameHtmlM Signature v
       e1' <- renderSigExp e1
       e2' <- renderSigExp e2
       return $ "(" <> name <> ": " <>
         e1' <> ") -> " <> e2'

vnameHtml :: VName -> Html
vnameHtml (VName name tag) =
  H.span ! A.id (fromString (show tag)) $ renderName name

vnameHtmlM :: Namespace -> VName -> DocM Html
vnameHtmlM ns (VName name tag) =
  do file <- asks fst
     modify (M.insert (ns,VName name tag) file)
     return $ H.span ! A.id (fromString (show tag)) $ renderName name

specHtml :: SpecBase Info VName -> DocM Html
specHtml spec = case spec of
  TypeAbbrSpec tpsig -> H.div <$> typeBindHtml tpsig
  TypeSpec name ps doc _ -> return . H.div $
    renderDoc doc <> "type " <> vnameHtml name <>
    joinBy " " (map prettyTypeParam ps)
  ValSpec name tparams params rettype doc _ -> return . H.div $
    renderDoc doc <>
    "val " <> vnameHtml name <>
    foldMap (" " <>) (map prettyTypeParam tparams) <> " : " <>
    foldMap (\tp -> paramBaseHtml tp <> " -> ") params <>
    typeDeclHtml rettype
  ModSpec name sig _ ->
    do m <- vnameHtmlM Structure name
       s <- renderSigExp sig
       return $ "module " <> m <> ": "<> s
  IncludeSpec e _ -> H.div . ("include " <>) <$> renderSigExp e

paramBaseHtml :: ParamBase Info VName -> Html
paramBaseHtml (NamedParam v t _) =
  parens $ vnameHtml v <> ": " <> typeDeclHtml t
paramBaseHtml (UnnamedParam t) = typeDeclHtml t

typeDeclHtml :: TypeDeclBase f VName -> Html
typeDeclHtml = typeExpHtml . declaredType

typeExpHtml :: TypeExp VName -> Html
typeExpHtml e = case e of
  TEUnique t _  -> "*" >> typeExpHtml t
  TEArray at d _ -> brackets (prettyDimDecl d) <> typeExpHtml at
  TETuple ts _ -> parens $ commas (map typeExpHtml ts)
  TERecord fs _ -> braces $ commas (map ppField fs)
    where ppField (name, t) = toHtml (nameToString name) <>
            "=" <> typeExpHtml t
  TEVar name  _ -> qualNameHtml name
  TEApply t args _ ->
    qualNameHtml t <> foldMap (" " <>) (map prettyTypeArgExp args)

qualNameHtml :: QualName VName -> Html
qualNameHtml (QualName names (VName name tag)) =
  if tag <= maxIntrinsicTag
      then prefix <> renderName name
      else prefix <> (a ! A.href (fromString ("#" ++ show tag)) $ renderName name)
  where prefix :: Html
        prefix = foldMap ((<> ".") . renderName) names

renderQualName :: Namespace -> QualName VName -> DocM Html
renderQualName ns (QualName names (VName name tag)) =
  if tag <= maxIntrinsicTag
      then return $ prefix <> renderName name
      else f <$> ref
  where prefix :: Html
        prefix = mapM_ ((<> ".") . renderName) names
        f s = prefix <> (a ! A.href (fromString s) $ renderName name)

        ref = do --vname <- getVName ns (QualName names name)
                 Just file <- gets (M.lookup (ns, VName name tag))
                 current <- asks fst
                 if file == current
                     then return ("#" ++ show tag)
                     else return $ relativise file current ++
                          ".html#" ++ show tag

relativise :: FilePath -> FilePath -> FilePath
relativise dest src =
  concat (replicate (length (splitPath src) - 2) "../") ++ dest

--getVName :: Namespace -> QualName Name -> DocM VName
--getVName ns (QualName names name) = do
--  (FileModule env)  <- asks snd
--  let nm = envNameMap (go names env)
--      Just vname = M.lookup (ns,name) nm
--  return vname
--  --return . (M.! (ns,name)) . envNameMap $ go names env
--  where go [] e = e
--        go (x:xs) e = go xs (f x e) --  $ f $ envModTable e M.! (envNameMap e M.! (Structure,x))
--        --f (ModEnv env) = env
--        f x e | Just y <- M.lookup (Structure,x) (envNameMap e)
--              , Just (ModEnv env) <- M.lookup y (envModTable e)
--              = env

prettyDimDecl :: DimDecl VName -> Html
prettyDimDecl AnyDim = mempty
prettyDimDecl (NamedDim v) = prettyQualName v
prettyDimDecl (ConstDim n) = toHtml (show n)

prettyTypeArgExp :: TypeArgExp VName -> Html
prettyTypeArgExp (TypeArgExpDim d _) = prettyDimDecl d
prettyTypeArgExp (TypeArgExpType d) = typeExpHtml d

prettyTypeParam :: TypeParam -> Html
prettyTypeParam (TypeParamDim name _) = brackets $ vnameHtml name
prettyTypeParam (TypeParamType name _) = "'" <> vnameHtml name

typeBindHtml :: TypeBindBase Info VName -> DocM Html
typeBindHtml (TypeBind name params usertype doc _) =
    return $ renderDoc doc <> typeHtml name params <> typeDeclHtml usertype

typeHtml :: VName -> [TypeParam] -> Html
typeHtml name params =
  "type " <> vnameHtml name <>
  joinBy " " (map prettyTypeParam params) <>
  " = "
