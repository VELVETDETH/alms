{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables #-}
module Statics (
  S, env0,
  tcProg, tcDecls,
  addVal, addTyTag
) where


import Util
import Syntax
import Env as Env
import Ppr ()

import Data.List (elemIndex)
import Data.Data (Typeable, Data)
import qualified Data.Map as M
import qualified Data.Set as S

import qualified Control.Monad.Reader as M.R
import qualified Control.Monad.State  as M.S

-- import System.IO.Unsafe (unsafePerformIO)
-- p :: (Show a, Monad m) => a -> TC w m ()
-- p = return . unsafePerformIO . print
-- p = const (return ())

-- Get the usage (sharing) of a variable in an expression:
usage :: Lid -> Expr i A -> Q
usage x e = case M.lookup x (fv e) of
  Just u | u > 1 -> Qu
  _              -> Qa

-- Type constructors are bound to either "type info" or a synonym
data TyInfo w = TiAbs TyTag
              | TiSyn [TyVar] (TypeT w)
              | TiDat TyTag [TyVar] (Env Uid (Maybe (TypeT w)))
  deriving (Data, Typeable)

-- Type environments
type D   = Env TyVar TyVar     -- tyvars in scope, with renaming
type G w = Env Ident (TypeT w) -- types of variables in scope
type I w = Env Lid (TyInfo w)  -- type constructors in scope

data S   = S {
             cVars   :: G C,
             aVars   :: G A,
             cTypes  :: I C,
             aTypes  :: I A,
             currIx  :: Integer
           }

-- The type checking monad
newtype TC w m a =
  TC { unTC :: M.R.ReaderT (TCEnv w) (M.S.StateT Integer m) a }
data TCEnv w = TCEnv (G w, G (OtherLang w)) (I w, I (OtherLang w)) (D, D)

instance Monad m => Monad (TC w m) where
  m >>= k = TC (unTC m >>= unTC . k)
  return  = TC . return
  fail    = TC . fail . ("Type error: "++)

asksM :: M.R.MonadReader r m => (r -> m a) -> m a
asksM  = (M.R.ask >>=)

saveTC :: (Language w, Monad m) => TC w m S
saveTC  = intoC . TC $ do
  TCEnv (g, g') (i, i') _ <- M.R.ask
  index                   <- M.S.get
  return S {
    cVars  = g,
    aVars  = g',
    cTypes = i,
    aTypes = i',
    currIx = index
  }

newtype WrapTC a m w = WrapTC { unWrapTC :: TC w m a }

runTC :: (Language w, Monad m) => S -> TC w m a -> m a
runTC gg0 m0 = langCase (WrapTC m0)
                 (runTCw (cVars, aVars) (cTypes, aTypes) gg0 . unWrapTC)
                 (runTCw (aVars, cVars) (aTypes, cTypes) gg0 . unWrapTC)
  where
    runTCw :: (Language w, Monad m) =>
              (S -> G w, S -> G (OtherLang w)) ->
              (S -> I w, S -> I (OtherLang w)) ->
              S -> TC w m a -> m a
    runTCw (getVars, getVars') (getTypes, getTypes') gg (TC m) = do
      let r0 = TCEnv (getVars gg, getVars' gg)
                     (getTypes gg, getTypes' gg)
                     (empty, empty)
          s0 = currIx gg
      M.S.evalStateT (M.R.runReaderT m r0) s0

data WrapGI w = WrapGI (G w) (I w)

intoC :: Language w => TC C m a -> TC w m a
intoC  = TC . M.R.withReaderT sw . unTC where
  sw (TCEnv (g, g') (i, i') (d, d')) =
    langCase (WrapGI g i)
      (\(WrapGI gC iC) -> TCEnv (gC, g') (iC, i') (d, d'))
      (\(WrapGI gA iA) -> TCEnv (g', gA) (i', iA) (d', d))

intoA :: Language w => TC A m a -> TC w m a
intoA  = TC . M.R.withReaderT sw . unTC where
  sw (TCEnv (g, g') (i, i') (d, d')) =
    langCase (WrapGI g i)
      (\(WrapGI gC iC)  -> langCase (WrapGI g' i')
          (\_           -> error "impossible! (Statics.intoA)")
          (\(WrapGI g'A i'A) -> TCEnv (g'A, gC) (i'A, iC) (d', d)))
      (\(WrapGI gA iA) -> TCEnv (gA, g') (iA, i') (d, d'))

outofC :: Language w => TC w m a -> TC C m a
outofC m = langCase (WrapTC m) unWrapTC (intoA . unWrapTC)

outofA :: Language w => TC w m a -> TC A m a
outofA m = langCase (WrapTC m) (intoC . unWrapTC) unWrapTC

newIndex :: Monad m => TC w m Integer
newIndex  = TC $ do
  M.S.modify (+ 1)
  M.S.get

withTVs :: Monad m => [TyVar] -> ([TyVar] -> TC w m a) -> TC w m a
withTVs tvs m = TC $ do
  TCEnv g ii (d, dw) <- M.R.ask
  let (d', tvs') = foldr rename (d, []) tvs
      r'         = TCEnv g ii (d', dw)
  M.R.local (const r') (unTC (m tvs'))
    where
      rename :: TyVar -> (D, [TyVar]) -> (D, [TyVar])
      rename tv (d, tvs') =
        let tv' = case d =.= tv of
              Nothing -> tv
              Just _  -> tv `freshTyVar` unEnv d
        in (d =+= tv =:= tv', tv':tvs')

withVars :: Monad m => G w -> TC w m a -> TC w m a
withVars g' = TC . M.R.local add . unTC where
  add (TCEnv (g, gw) ii dd) = TCEnv (g =+= g', gw) ii dd

withTypes :: Monad m => I w -> TC w m a -> TC w m a
withTypes i' = TC . M.R.local add . unTC where
  add (TCEnv g (i, iw) dd) = TCEnv g (i =+= i', iw) dd

withoutConstructors :: Monad m => TyTag -> TC w m a -> TC w m a
withoutConstructors tag = TC . M.R.local clean . unTC where
  clean (TCEnv (g, gw) ii dd) =
    TCEnv (fromList (filter keep (toList g)), gw) ii dd
  keep (Con _, TyCon _ [_, TyCon _ _ tag'] _) = tag' /= tag
  keep (Con _, TyCon _ _ tag')                = tag' /= tag
  keep _                                      = True

withReplacedTyTags :: (Language w, Data w, Monad m) =>
                      TyTag -> TC w m a -> TC w m a
withReplacedTyTags tag = TC . M.R.local replace . unTC where
  replace (TCEnv (g, g') (i, i') dd) =
    langCase (WrapGI g i)
      (\_ -> TCEnv (r g, r g') (r i, r i') dd)
      (\_ -> TCEnv (r g, r g') (r i, r i') dd)
  r a = replaceTyTags tag a

getTV :: Monad m => TyVar -> TC w m TyVar
getTV tv = TC $ asksM check where
  check (TCEnv _ _ (d, _)) = case d =.= tv of
    Just tv' -> return tv'
    _        -> fail $ "Free type variable: " ++ show tv

getVar :: Monad m => Ident -> TC w m (TypeT w)
getVar x = TC $ asksM get where
  get (TCEnv (g, _) _ _) = g =.= x
    |! "Unbound variable: " ++ show x

tryGetVar :: Monad m => Ident -> TC w m (Maybe (TypeT w))
tryGetVar x = TC $ asksM get where
  get (TCEnv (g, _) _ _) = return (g =.= x)

getType :: Monad m => Lid -> TC w m (TyInfo w)
getType n = TC $ asksM get where
  get (TCEnv _ (i, _) _) = i =.= n
    |! "Unbound type constructor: " ++ show n

getTypeTag :: Monad m => String -> Lid -> TC w m TyTag
getTypeTag who n = do
  ti <- getType n
  case ti of
    TiAbs td     -> return td
    TiSyn _ _    -> fail $
      who ++ " expects an abstract or data type, but " ++
      "got type synonym: " ++ show n
    TiDat td _ _ -> return td

-- A type checking "assertion" raises a type error if the
-- asserted condition is false.
tassert :: Monad m => Bool -> String -> m ()
tassert True  _ = return ()
tassert False s = fail s

-- A common form of type error
tgot :: Monad m => String -> Type i w -> String -> m a
tgot who got expected = fail $ who ++ " got " ++ show got ++
                               " where " ++ expected ++ " expected"

-- Combination of tassert and tgot
tassgot :: Monad m => Bool -> String -> Type i w -> String -> m ()
tassgot False = tgot
tassgot True  = \_ _ _ -> return ()

-- Run a partial computation, and if it fails, substitute
-- the given failure message.
(|!) :: Monad m => Maybe a -> String -> m a
m |! s = case m of
  Just r  -> return r
  _       -> fail s
infix 1 |!

-- Check type for closed-ness and and defined-ness, and add info
tcType :: (Language w, Monad m) => Type i w -> TC w m (TypeT w)
tcType = tc where
  tc :: (Language w, Monad m) => Type i w -> TC w m (TypeT w)
  tc (TyVar tv)   = do
    tv' <- getTV tv
    return (TyVar tv')
  tc (TyCon n ts _) = do
    ts'  <- mapM tc ts
    tcon <- getType n
    case tcon of
      TiAbs td -> do
        checkLength (length (ttArity td))
        return (TyCon n ts' td)
      TiSyn ps t -> return (tysubsts ps ts' t)
      TiDat td _ _ -> do
        checkLength (length (ttArity td))
        return (TyCon n ts' td)
    where
      checkLength len =
        tassert (length ts == len) $
          "Type constructor " ++ show n ++ " applied to " ++
          show (length ts) ++ " arguments where " ++
          show len ++ " expected"
  tc (TyAll tv t) = withTVs [tv] $ \[tv'] -> TyAll tv' `liftM` tc t
  tc (TyMu  tv t) = withTVs [tv] $ \[tv'] -> do
    t' <- tc t
    langCase t'
      (\_ -> return ())
      (\_ -> tassert (qualifier t' == tvqual tv) $
         "Recursive type " ++ show (TyMu tv t) ++ " qualifier " ++
         "does not match its own type variable.")
    return (TyMu tv' t')
  tc (TyC t)      = ctype2atype `liftM` intoC (tc t)
  tc (TyA t)      = atype2ctype `liftM` intoA (tc t)

-- Given a list of type variables and types, perform all the
-- substitutions, avoiding capture between them.
tysubsts :: Language w => [TyVar] -> [TypeT w] -> TypeT w -> TypeT w
tysubsts ps ts t =
  let ps'     = freshTyVars ps (ftv (t:ts))
      substs :: Language w =>
                [TyVar] -> [TypeT w] -> TypeT w -> TypeT w
      substs tvs ts0 t0 = foldr2 tysubst t0 tvs ts0 in
  substs ps' ts .
    substs ps (map TyVar ps') $
      t

-- Type check an expression
tcExprC :: Monad m => Expr i C -> TC C m (TypeT C, ExprT C)
tcExprC = tc where
  tc :: Monad m => Expr i C -> TC C m (TypeT C, ExprT C)
  tc e0 = case view e0 of
    ExId x -> do
      tx <- getVar x
      return (tx, exId x)
    ExStr s       -> return (TyCon (Lid "string") [] tdString, exStr s)
    ExInt z       -> return (TyCon (Lid "int") [] tdInt, exInt z)
    ExFloat f     -> return (TyCon (Lid "float") [] tdFloat, exFloat f)
    ExCase e1 clauses -> do
      (t1, e1') <- tc e1
      (ti:tis, clauses') <- liftM unzip . forM clauses $ \(xi, ei) -> do
        (gi, xi') <- tcPatt t1 xi
        (ti, ei') <- withVars gi $ tc ei
        return (ti, (xi', ei'))
      forM_ tis $ \ti' ->
        tassert (ti == ti') $
          "Mismatch in match/let: " ++ show ti ++ " /= " ++ show ti'
      return (ti, exCase e1' clauses')
    ExLetRec bs e2 -> do
      tfs <- mapM (tcType . bntype) bs
      let makeG seen (b:bs') (t:ts') = do
            tassert (bnvar b `notElem` seen) $
              "Duplicate binding in let rec: " ++ show (bnvar b)
            tassert (syntacticValue (bnexpr b)) $
              "Not a syntactic value in let rec: " ++ show (bnexpr b)
            g' <- makeG (bnvar b : seen) bs' ts'
            return (g' =+= Var (bnvar b) =:= t)
          makeG _    _       _       = return empty
      g'  <- makeG [] bs tfs
      (tas, e's) <- unzip `liftM` mapM (withVars g' . tc . bnexpr) bs
      zipWithM_ (\tf ta -> do
                   tassert (tf == ta) $
                      "Actual type " ++ show ta ++
                      " does not agree with declared type " ++
                      show tf ++ " in let rec")
                tfs tas
      (t2, e2') <- withVars g' (tc e2)
      let b's = zipWith3 (\b tf e' -> b { bntype = tf, bnexpr = e' })
                         bs tfs e's
      return (t2, exLetRec b's e2')
    ExPair e1 e2  -> do
      (t1, e1') <- tc e1
      (t2, e2') <- tc e2
      return (TyCon (Lid "*") [t1, t2] tdTuple, exPair e1' e2')
    ExAbs x t e     -> do
      t' <- tcType t
      (gx, x') <- tcPatt t' x
      (te, e') <- withVars gx $ tc e
      return (tyArrT t' te, exAbs x' t' e')
    ExApp _ _     -> do
      tcExApp (==) tc e0
    ExTAbs tv e   ->
      withTVs [tv] $ \[tv'] -> do
        (t, e') <- tc e
        return (TyAll tv' t, exTAbs tv' e')
    ExTApp e1 t2  -> do
      (t1, e1') <- tc e1
      t2'       <- tcType t2
      t1'       <- tapply t1 t2'
      return (t1', exTApp e1' t2')
    ExCast e1 t ta -> do
      t'  <- tcType t
      ta' <- intoA $ tcType ta
      tassgot (castableType t')
        "cast (:>)" t' "function type"
      (t1, e1') <- tc e1
      tassert (t1 == t') $
        "Mismatch in cast: declared type " ++ show t' ++
        " doesn't match actual type " ++ show t1
      tassert (t1 == atype2ctype ta') $
        "Mismatch in cast: C type " ++ show t1 ++
        " is incompatible with A contract " ++ show t'
      return (t', exCast e1' t' ta')

tcExprA :: Monad m => Expr i A -> TC A m (TypeT A, ExprT A)
tcExprA = tc where
  tc :: Monad m => Expr i A -> TC A m (TypeT A, ExprT A)
  tc e0 = case view e0 of
    ExId x -> do
      tx <- getVar x
      return (tx, exId x)
    ExStr s       -> return (TyCon (Lid "string") [] tdString, exStr s)
    ExInt z       -> return (TyCon (Lid "int") [] tdInt, exInt z)
    ExFloat f     -> return (TyCon (Lid "float") [] tdFloat, exFloat f)
    ExCase e clauses -> do
      (t0, e') <- tc e
      (t1:ts, clauses') <- liftM unzip . forM clauses $ \(xi, ei) -> do
        (gi, xi') <- tcPatt t0 xi
        checkSharing "match" gi ei
        (ti, ei') <- withVars gi $ tc ei
        return (ti, (xi', ei'))
      tr <- foldM (\ti' ti -> ti' \/? ti
                      |! "Mismatch in match/let: " ++ show ti ++
                          " and " ++ show ti')
            t1 ts
      return (tr, exCase e' clauses')
    ExLetRec bs e2 -> do
      tfs <- mapM (tcType . bntype) bs
      let makeG seen (b:bs') (t:ts') = do
            tassert (bnvar b `notElem` seen) $
              "Duplicate binding in let rec: " ++ show (bnvar b)
            tassert (syntacticValue (bnexpr b)) $
              "Not a syntactic value in let rec: " ++ show (bnexpr b)
            tassert (qualifier t <: Qu) $
              "Affine type in let rec binding: " ++ show t
            g' <- makeG (bnvar b : seen) bs' ts'
            return (g' =+= Var (bnvar b) =:= t)
          makeG _    _       _       = return empty
      g'  <- makeG [] bs tfs
      (tas, e's) <- unzip `liftM` mapM (withVars g' . tc . bnexpr) bs
      zipWithM_ (\tf ta ->
                   tassert (ta <: tf) $
                      "Actual type " ++ show ta ++
                      " does not agree with declared type " ++
                      show tf ++ " in let rec")
                tfs tas
      (t2, e2') <- withVars g' $ tc e2
      let b's = zipWith3 (\b tf e' -> b { bntype = tf, bnexpr = e' })
                         bs tfs e's
      return (t2, exLetRec b's e2')
    ExPair e1 e2  -> do
      (t1, e1') <- tc e1
      (t2, e2') <- tc e2
      return (TyCon (Lid "*") [t1, t2] tdTuple, exPair e1' e2')
    ExAbs x t e     -> do
      t' <- tcType t
      (gx, x') <- tcPatt t' x
      checkSharing "lambda" gx e
      (te, e') <- withVars gx $ tc e
      unworthy <- isUnworthy e0
      if unworthy
        then return (tyLolT t' te, exAbs x' t' e')
        else return (tyArrT t' te, exAbs x' t' e')
    ExApp _  _    -> do
      tcExApp (<:) tc e0
    ExTAbs tv e   ->
      withTVs [tv] $ \[tv'] -> do
        (t, e') <- tc e
        return (TyAll tv' t, exTAbs tv' e')
    ExTApp e1 t2  -> do
      (t1, e1') <- tc e1
      t2'       <- tcType t2
      t1'       <- tapply t1 t2'
      return (t1', exTApp e1' t2')
    ExCast e1 t ta -> do
      t'  <- tcType t
      ta' <- tcType ta
      tassgot (castableType t')
        "cast (:>)" t' "function type"
      (t1, e1') <- tc e1
      tassgot (t1 <: t')
        "cast (:>)" t1 (show t')
      t1 \/? ta' |!
        "Mismatch in cast: types " ++ show t1 ++
        " and " ++ show t' ++ " are incompatible"
      return (ta', exCast e1' t' ta')

  checkSharing name g e =
    forM_ (toList g) $ \(x, tx) ->
      case x of
        Var x' ->
          tassert (qualifier tx <: usage x' e) $
            "Affine variable " ++ show x' ++ " : " ++
            show tx ++ " duplicated in " ++ name ++ " body"
        _ -> return ()

  isUnworthy e =
    anyM (\x -> do
           mtx <- tryGetVar (Var x)
           return $ case mtx of
             Just tx -> qualifier tx == Qa
             Nothing -> False)
         (M.keys (fv e))

tcExApp :: (Language w, Monad m) =>
           (TypeT w -> TypeT w -> Bool) ->
           (Expr i w -> TC w m (TypeT w, ExprT w)) ->
           Expr i w -> TC w m (TypeT w, ExprT w)
tcExApp (<::) tc e0 = do
  let foralls t1 ts = do
        let (tvs, t1f)  = unfoldTyAll t1     -- peel off quantification
            (tas, _)    = unfoldTyFun t1f    -- peel off arg types
            nargs       = min (length tas) (length ts)
            tup ps      = TyCon (Lid "") (take nargs ps) tdTuple
        -- try to find types to unify formals and actuals, and apply
        t1' <- tryUnify tvs (tup tas) (tup ts) >>= foldM tapply t1
        arrows t1' ts
      arrows tr             [] = return tr
      arrows t'@(TyAll _ _) ts = foralls t' ts
      arrows (TyCon _ [ta, tr] td) (t:ts) | td `elem` funtypes = do
        b <- unifies [] t ta
        tassgot b "Application (operand)" t (show ta)
        arrows tr ts
      arrows t' _ = tgot "Application (operator)" t' "function type"
      unifies tvs ta tf =
        case tryUnify tvs ta tf of
          Just ts  -> do
            ta' <- foldM tapply (foldr TyAll ta tvs) ts
            if (ta' <:: tf)
              then return True
              else deeper
          Nothing -> deeper
        where
          deeper = case ta of
            TyAll tv ta1 -> unifies (tvs++[tv]) ta1 tf
            _            -> return False
  let (es, e1) = unfoldExApp e0            -- get operator and args
  (t1, e1')   <- tc e1                     -- check operator
  (ts, es')   <- unzip `liftM` mapM tc es  -- check args
  tr <- foralls t1 ts
  return (tr, foldl exApp e1' es')

tapply :: (Language w, Monad m) =>
          TypeT w -> TypeT w -> m (TypeT w)
tapply (TyAll tv t1') t2 = do
  langCase t2
    (\_ -> return ())
    (\_ ->
      tassert (qualifier t2 <: tvqual tv) $
        "Type application cannot instantiate type variable " ++
        show tv ++ " with type " ++ show t2)
  return (tysubst tv t2 t1')
tapply t1 _ = tgot "type application" t1 "(for)all type"

tcPatt :: (Monad m, Language w) =>
          TypeT w -> Patt -> TC w m (G w, Patt)
tcPatt t x0 = case x0 of
  PaWild     -> return (empty, PaWild)
  PaVar x    -> return (Var x =:= t, PaVar x)
  PaCon u mx -> do
    case t of
      TyCon name ts tag -> do
        tcon <- getType name
        case tcon of
          TiDat tag' params alts | tag == tag' -> do
            case alts =.= u of
              Nothing -> tgot "Pattern" t ("constructor " ++ show u)
              Just mt -> case (mt, mx) of
                (Nothing, Nothing) -> return (empty, PaCon u Nothing)
                (Just t1, Just x1) -> do
                  let t1' = tysubsts params ts t1
                  (gx1, x1') <- tcPatt t1' x1
                  return (gx1, PaCon u (Just x1'))
                _ -> tgot "Pattern" t "different arity"
          _ ->
            fail $ "Pattern " ++ show x0 ++ " for type not in scope"
      _ -> tgot "Pattern" t ("constructor " ++ show u)
  PaPair x y -> do
    case t of
      TyCon (Lid "*") [tx, ty] td | td == tdTuple
        -> do
          (gx, x') <- tcPatt tx x
          (gy, y') <- tcPatt ty y
          tassert (isEmpty (gx =|= gy)) $
            "Pattern " ++ show x0 ++ " binds variable twice"
          return (gx =+= gy, PaPair x' y')
      _ -> tgot "Pattern" t "pair type"
  PaStr s    -> do
    tassgot (tyinfo t == tdString)
      "Pattern" t "string"
    return (empty, PaStr s)
  PaInt z    -> do
    tassgot (tyinfo t == tdInt)
      "Pattern" t "int"
    return (empty, PaInt z)
  PaAs x y   -> do
    (gx, x') <- tcPatt t x
    let gy    = Var y =:= t
    tassert (isEmpty (gx =|= gy)) $
      "Pattern " ++ show x0 ++ " binds " ++ show y ++ " twice"
    return (gx =+= gy, PaAs x' y)

-- Given a list of type variables tvs, an type t in which tvs
-- may be free, and a type t', tries to substitute for tvs in t
-- to produce a type that *might* unify with t'
tryUnify :: (Monad m, Language w) =>
            [TyVar] -> TypeT w -> TypeT w -> m [TypeT w]
tryUnify [] _ _        = return []
tryUnify (tv:tvs) t t' =
  case findSubst tv t t' of
    tguess:_ -> do
                  let subst' = tysubst tv tguess
                  tguesses <- tryUnify tvs (subst' t) t'
                  return (tguess : tguesses)
    _        -> fail $
                  "Cannot guess type t such that (" ++ show t ++
                  ")[t/" ++ show tv ++ "] ~ " ++ show t'

-- Given a type variable tv, type t in which tv may be free,
-- and a second type t', finds a plausible candidate to substitute
-- for tv to make t and t' unify.  (The answer it finds doesn't
-- have to be correct.
findSubst :: forall w. Language w => TyVar -> TypeT w -> TypeT w -> [TypeT w]
findSubst tv = chk True [] where
  chk, cmp :: Language w' =>
              Bool -> [(TypeTW, TypeTW)] -> TypeT w' -> TypeT w' -> [TypeT w']
  chk b seen t1 t2 =
    let tw1 = typeTW t1; tw2 = typeTW t2
     in if (tw1, tw2) `elem` seen
          then []
          else cmp b ((tw1, tw2) : seen) t1 t2

  cmp True _  (TyVar tv') t'
    | tv == tv'    = [t']
  cmp False _ (TyA (TyVar tv')) t'
    | tv == tv'    = [t']
  cmp False _ (TyC (TyVar tv')) t'
    | tv == tv'    = [t']
  cmp b seen (TyCon _ [t] td) t'
    | td == tdDual = chk b seen (dualSessionType t) t'
  cmp b seen t' (TyCon _ [t] td)
    | td == tdDual = chk b seen t' (dualSessionType t)
  cmp b seen (TyCon _ ts _) (TyCon _ ts' _)
                   = concat (zipWith (chk b seen) ts ts')
  cmp b seen (TyAll tv0 t) (TyAll tv0' t')
    | tv /= tv0    = [ tr | tr <- chk b seen t t',
                            not (tv0  `M.member` ftv tr),
                            not (tv0' `M.member` ftv tr) ]
  cmp b seen (TyC t) (TyC t')
                   = ctype2atype `map` cmp (not b) seen t t'
  cmp b seen (TyA t) (TyA t')
                   = atype2ctype `map` cmp (not b) seen t t'
  cmp b seen (TyMu a t) t'
                   = chk b seen (tysubst a (TyMu a t) t) t'
  cmp b seen t' (TyMu a t)
                   = chk b seen t' (tysubst a (TyMu a t) t)
  cmp _ _ _ _        = []

indexQuals :: Monad m =>
              Lid -> [TyVar] -> [Either TyVar Q] -> TC w m [Either Int Q]
indexQuals name tvs = mapM each where
  each (Left tv) = case tv `elemIndex` tvs of
    Nothing -> fail $ "unbound tyvar " ++ show tv ++
                      " in qualifier list for type " ++ show name
    Just n  -> return (Left n)
  each (Right q) = return (Right q)

withTyDec :: (Language w, Monad m) =>
           TyDec -> (TyDec -> TC w m a) -> TC w m a
withTyDec (TdAbsA name params variances quals) k = intoA $ do
  index  <- newIndex
  quals' <- indexQuals name params quals
  withTypes (name =:= TiAbs TyTag {
               ttId    = index,
               ttArity = variances,
               ttQual  = quals',
               ttTrans = False
             })
    (outofA . k $ TdAbsA name params variances quals)
withTyDec (TdAbsC name params) k = intoC $ do
  index <- newIndex
  withTypes (name =:= TiAbs TyTag {
               ttId    = index,
               ttArity = map (const Invariant) params,
               ttQual  = [],
               ttTrans = False
             })
    (outofC . k $ TdAbsC name params)
withTyDec (TdSynC name params rhs) k = intoC $ do
  t' <- withTVs params $ \params' -> TiSyn params' `liftM` tcType rhs
  withTypes (name =:= t')
    (outofC . k $ TdSynC name params rhs)
withTyDec (TdSynA name params rhs) k = intoA $ do
  t' <- withTVs params $ \params' -> TiSyn params' `liftM` tcType rhs
  withTypes (name =:= t')
    (outofA . k $ TdSynA name params rhs)
withTyDec (TdDatC name params alts) k = intoC $ do
  index <- newIndex
  let tag = TyTag {
              ttId    = index,
              ttArity = map (const Invariant) params,
              ttQual  = [],
              ttTrans = False
            }
  (params', alts') <-
    withTVs params $ \params' ->
      withTypes (name =:= TiDat tag params' empty) $ do
        alts' <- sequence
          [ case mt of
              Nothing -> return (cons, Nothing)
              Just t  -> do
                t' <- tcType t
                return (cons, Just t')
          | (cons, mt) <- alts ]
        return (params', alts')
  withTypes (name =:= TiDat tag params' (fromList alts')) $
    withVars (alts2env name params' tag alts') $
      (outofC . k $ TdDatC name params alts)
withTyDec (TdDatA name params alts) k = intoA $ do
  index <- newIndex
  let tag0 = TyTag {
               ttId    = index,
               ttArity = map (const 0) params,
               ttQual  = [],
               ttTrans = False
             }
  (tag, alts') <- fixDataType name params alts tag0
  withTypes (name =:= TiDat tag params (fromList alts')) $
    withVars (alts2env name params tag alts') $
      (outofA . k $ TdDatA name params alts)

fixDataType :: Monad m =>
               Lid -> [TyVar] -> [(Uid, Maybe (Type () A))] ->
               TyTag -> TC A m (TyTag, [(Uid, Maybe (TypeT A))])
fixDataType name params alts = loop where
  loop :: Monad m => TyTag -> TC A m (TyTag, [(Uid, Maybe (TypeT A))])
  loop tag = do
    (params', alts') <-
      withTVs params $ \params' ->
        withTypes (name =:= TiDat tag params' empty) $ do
          alts' <- sequence
            [ case mt of
                Nothing -> return (k, Nothing)
                Just t  -> do
                  t' <- tcType t
                  return (k, Just t')
            | (k, mt) <- alts ]
          return (params', alts')
    let t'    = foldl tyTupleT tyUnitT [ t | (_, Just t) <- alts' ]
        arity = typeVariances params' t'
        qual  = typeQual params' t'
    if arity == ttArity tag && qual == ttQual tag
      then return (tag, alts')
      else loop tag {
             ttArity = arity,
             ttQual  = qual
           }

alts2env :: Lid -> [TyVar] -> TyTag -> [(Uid, Maybe (TypeT w))] -> G w
alts2env name params tag = fromList . map each where
  each (uid, Nothing) = (Con uid, alls result)
  each (uid, Just t)  = (Con uid, alls (t `tyArrT` result))
  alls t              = foldr TyAll t params
  result              = TyCon name (map TyVar params) tag

typeVariances :: [TyVar] -> TypeT A -> [Variance]
typeVariances d0 = finish . loop where
  finish m = [ maybe 0 id (M.lookup tv m)
             | tv <- d0 ]

  loop :: TypeT A -> M.Map TyVar Variance
  loop (TyCon _ ts info)
                    = M.unionsWith (\/)
                        (zipWith
                          (\t v -> M.map (* v) (loop t))
                          ts
                          (ttArity info))
  loop (TyVar tv)   = M.singleton tv 1
  loop (TyAll tv t) = M.delete tv (loop t)
  loop (TyMu tv t)  = M.delete tv (loop t)
  loop (TyC t)      = loopC t
  loop _            = error "Can't get TyA here"

  loopC :: TypeT C -> M.Map TyVar Variance
  loopC (TyCon _ ps _) = M.unionsWith (\/) (map loopC ps)
  loopC (TyVar _)      = M.empty
  loopC (TyAll _ t)    = loopC t
  loopC (TyMu _ t)     = loopC t
  loopC (TyA t)        = M.map (const Invariant) (loop t)
  loopC _              = error "Can't get TyC here"

typeQual :: [TyVar] -> TypeT A -> [Either Int Q]
typeQual d0 = finish . loop where
  finish es = [ e | Just e <-
                  [ case e of
                      Right q -> Just (Right q)
                      Left tv -> fmap Left (elemIndex tv d0)
                  | e <- S.toList es ] ]

  loop :: TypeT A -> S.Set (Either TyVar Q)
  loop (TyCon _ ts info)
                    = S.unions
                        [ case qual of
                            Right q -> S.singleton (Right q)
                            Left i  -> loop (ts !! i)
                        | qual <- ttQual info ]
  loop (TyVar tv)   = S.singleton (Left tv)
  loop (TyAll tv t) = S.delete (Left tv) (loop t)
  loop (TyMu tv t)  = S.delete (Left tv) (loop t)
  loop _            = S.empty

withMod :: (Language w, Monad m) =>
         Mod i -> (ModT -> TC w m a) -> TC w m a
withMod (MdC x mt e) k = intoC $ do
  (te, e') <- tcExprC e
  t' <- case mt of
    Just t  -> do
      t' <- tcType t
      tassert (te == t') $
        "Declared type for module " ++ show x ++ " : " ++ show t ++
        " doesn't match actual type " ++ show te
      return t'
    Nothing -> return te
  withVars (Var x =:= t') .
    intoA .
      withVars (Var x =:= ctype2atype t') .
        outofA .
          k $ MdC x (Just t') e'
withMod (MdA x mt e) k = intoA $ do
  (te, e') <- tcExprA e
  t' <- case mt of
    Just t  -> do
      t' <- tcType t
      tassert (qualifier t' == Qu) $
        "Declared type of module " ++ show x ++ " is not unlimited"
      tassert (te <: t') $
        "Declared type for module " ++ show x ++ " : " ++ show t' ++
        " is not subsumed by actual type " ++ show te
      return t'
    Nothing -> do
      tassert (qualifier te == Qu) $
        "Type of module " ++ show x ++ " is not unlimited"
      return te
  withVars (Var x =:= t') .
    intoC .
      withVars (Var x =:= atype2ctype t') .
        outofC .
          k $ MdA x (Just t') e'
withMod (MdInt x t y) k = do
  ty <- intoC $ getVar (Var y)
  t' <- intoA $ tcType t
  tassert (ty == atype2ctype t') $
    "Declared type of interface " ++ show x ++ " :> " ++
    show t' ++ " not compatible with RHS type: " ++ show ty
  intoA .
    withVars (Var x =:= t') .
      intoC .
        withVars (Var x =:= atype2ctype t') .
          outofC .
            k $ MdInt x t' y

withDecl :: Monad m =>
            Decl i -> (DeclT -> TC C m a) -> TC C m a
withDecl (DcMod m)     k = withMod m (k . DcMod)
withDecl (DcTyp td)    k = withTyDec td (k . DcTyp)
withDecl (DcAbs at ds) k = withAbsTy at ds (k . DcAbs at)

withDecls :: Monad m => [Decl i] -> ([DeclT] -> TC C m a) -> TC C m a
withDecls []     k = k []
withDecls (d:ds) k = withDecl d $ \d' ->
                       withDecls ds $ \ds' ->
                         k (d':ds')

withAbsTy :: Monad m =>
             AbsTy -> [Decl i] -> ([DeclT] -> TC C m a) -> TC C m a
withAbsTy at ds k = case at of
  AbsTyC name params alts ->
    withTyDec (TdDatC name params alts) $ \_ ->
      withDecls ds $ \ds' -> do
        tag <- getTypeTag "abstract-with-end" name
        tassert (length params == length (ttArity tag)) $
          "abstract-with-end: " ++ show (length params) ++
          " given for type " ++ show name ++
          " which has " ++ show (length (ttArity tag))
        let tag' = tag
        withoutConstructors tag' .
          withReplacedTyTags tag' .
            withTypes (name =:= TiAbs tag') $
              k (replaceTyTags tag' ds')
  AbsTyA name params arity quals alts ->
    withTyDec (TdDatA name params alts) $ \_ ->
      withDecls ds $ \ds' -> intoA $ do
      tag    <- getTypeTag "abstract-with-end" name
      quals' <- indexQuals name params quals
      tassert (length params == length (ttArity tag)) $
        "abstract-with-end: " ++ show (length params) ++
        " given for type " ++ show name ++
        " which has " ++ show (length (ttArity tag))
      tassert (all2 (<:) (ttArity tag) arity) $
        "abstract-with-end: declared arity for type " ++ show name ++
        ", " ++ show arity ++
        ", is more general than actual arity " ++ show (ttArity tag)
      let oldIndices  = [ ix | Left ix <- ttQual tag ]
          newIndices  = [ ix | Left ix <- quals' ]
          oldConstant = bigVee [ q | Right q <- ttQual tag ]
          newConstant = bigVee [ q | Right q <- quals' ]
      tassert (oldConstant <: newConstant &&
               all (`elem` newIndices) oldIndices) $
        "abstract-with-end: declared qualifier for type " ++ show name ++
        ", " ++ show quals ++
        ", is more general than actual qualifier"
      let tag' = TyTag (ttId tag) arity quals' False
      withoutConstructors tag' .
        withReplacedTyTags tag' .
          withTypes (name =:= TiAbs tag') .
            outofA $
              k (replaceTyTags tag' ds')

tcDecls :: Monad m => S -> [Decl i] -> m (S, [DeclT])
tcDecls gg ds = runTC gg $
                  withDecls ds $ \ds' -> do
                    gg' <- saveTC
                    return (gg', ds')

-- For adding types of primitives to the environment
addVal :: (Language w, Monad m) => S -> Ident -> Type i w -> m S
addVal gg x t = runTC gg $ do
  t' <- tcType t
  withVars (x =:= t') saveTC

addTyTag :: S -> Lid -> TyTag -> S
addTyTag gg n td =
  gg {
    cTypes = cTypes gg =+= n =:= TiAbs td,
    aTypes = aTypes gg =+= n =:= TiAbs td
  }

-- Type check a program
tcProg :: Monad m => S -> Prog i -> m (TypeT C, ProgT)
tcProg gg (Prog ds me) =
  runTC gg $
    withDecls ds $ \ds' -> do
      (t, e') <- case me of
                   Just e  -> do
                     (t, e') <- tcExprC e
                     return (t, Just e')
                   Nothing -> do
                     return (tyUnitT, Nothing)
      return (t, Prog ds' e')

env0 :: S
env0 = S g0 g0 i0 i0 0 where
  g0 :: G w
  g0  = Con (Uid "()")    =:= tyUnitT =+=
        Con (Uid "true")  =:= tyBoolT =+=
        Con (Uid "false") =:= tyBoolT
  i0 :: I w
  i0  = Lid "unit" =:= TiDat tdUnit [] (
          Uid "()"    =:= Nothing
        ) =+=
        Lid "bool" =:= TiDat tdBool [] (
          Uid "true"  =:= Nothing =+=
          Uid "false" =:= Nothing
        )
