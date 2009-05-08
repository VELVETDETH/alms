module Translation (
  translate, transMods, MEnv,
) where

import Syntax
import Env

type MEnv = Env Var Mod

-- Parties to contracts are module names, but it's worth
-- keeping them separate from regular variables.
newtype Party = Party { unParty :: Var }

-- Translate a program by adding contracts.
-- Also performs some *trivial* optimizations.
translate :: Prog -> Prog
translate (Prog ms e) =
  Prog ms' (transExpr menv (Party (Var "*main*")) e)
  where (menv, ms') = transMods empty ms

transMods :: MEnv -> [Mod] -> (MEnv, [Mod])
transMods menv = foldl each (menv, []) where
  each (env, ms) m = let (env', m') = transMod env m
                      in (env', ms ++ [m'])

transMod :: MEnv -> Mod -> (MEnv, Mod)
transMod menv m@(MdC x (Just t) e) =
  (menv =+= x =:= m,
   MdC x (Just t) (transExpr menv (Party x) e))
transMod menv m@(MdA x (Just t) e) =
  (menv =+= x =:= m,
   MdC x (Just (atype2ctype t)) (transExpr menv (Party x) e))
transMod menv m@(MdInt x t y)      =
  (menv =+= x =:= m,
   MdC x (Just (atype2ctype t)) $
     exLet' z (transExpr menv (Party x) (exVar y :: Expr C)) $
       ac (Party y) (Party x) z t)
    where z = y /./ "z"
transMod menv m                  =
  (menv =+= modName m =:= m, m)

transExpr :: Language w => MEnv -> Party -> Expr w -> Expr C
transExpr menv neg = te where
  tem menv' = transExpr menv' neg
  te e0 = case expr' e0 of
    ExCon s -> exCon s
    ExStr s -> exStr s
    ExInt z -> exInt z
    ExIf ec et ef -> exIf (te ec) (te et) (te ef)
    ExCase e1 (xl, el) (xr, er) -> exCase (te e1)
                                     (xl, tem (menv =-= xl) el)
                                     (xr, tem (menv =-= xr) er)
    ExLet x e1 e2 -> exLet' x (te e1) (tem (menv =-= x) e2)
    ExLetRec bs e2 -> let rec  = tem (foldl (=-=) menv (map bnvar bs))
                      in exLetRec
                           [ Binding x (type2ctype t) (rec e)
                           | Binding x t e <- bs ]
                           (rec e2)
    ExVar x -> transVar (reifyLang1 e0) menv neg x
    ExPair e1 e2 -> exPair (te e1) (te e2)
    ExLetPair (x, y) e1 e2 -> exLetPair (x, y) (te e1)
                                (tem (menv =-= x =-= y) e2)
    ExAbs x t e -> exAbs' x (type2ctype t) (tem (menv =-= x) e)
    ExApp e1 e2 -> exApp (te e1) (te e2)
    ExTAbs tv e -> exTAbs' tv (te e)
    ExTApp e1 t2 -> exTApp (te e1) (type2ctype t2)
    ExSeq e1 e2 -> exSeq (te e1) (te e2)
    ExCast e1 t ta -> transCast neg (te e1) t ta

type2ctype :: Language w => Type w -> Type C
type2ctype t = langCase t id atype2ctype

-- Get the LangRep from a term:
reifyLang1 :: Language w => f w -> LangRep w
reifyLang1 _ = reifyLang

-- How do we refer to a variable from a given language?
transVar :: LangRep w -> MEnv -> Party -> Var -> Expr C
transVar lang menv neg x =
  case (lang, menv =.= x) of
    (C, Just (MdC _ (Just t) _)) -> cc neg (Party x) x t
    (C, Just (MdA _ (Just t) _)) -> ca neg (Party x) x t
    (C, Just (MdInt _ t _))      -> ca neg (Party x) x t
    (A, Just (MdC _ (Just t) _)) -> ac neg (Party x) x (ctype2atype t)
    _                            -> exVar x

-- Translate a cast ("dynamic promotion")
--
--  - In C, given (e : t :> ta), we know that e follows t, but we have
--    no reason to believe it follows ta, nor does its context.  Thus,
--    we protect in both directions by ta.
--
--  - In A, given (e : t :> ta), we know from A's type system that e
--    follows t and the context follows ta.  Thus, we need ensure that
--    e follows ta and that the context follows t.
--
transCast :: Language w => Party -> Expr C -> Type w -> Type A -> Expr C
transCast neg e t' ta =
  exLet' y e $
    exLet' z (ac neg pos y ta) $   -- protect the value
      langCase t'
        (\_ -> ca neg pos z ta)    -- protect the context, or
        (\t -> ca neg pos z t)     -- protect the context
  where y = unParty neg /./ "y"
        z = unParty neg /./ "z"
        pos = neg /^/ "(:>)"

-- Given negative and positive blame labels, the name of an A
-- language variable we wish to protect, and the A type the variable
-- should have, generates an expression that projects that variable.
--
-- This wrapper protects the positive party and may blame the
-- negative party.
ca :: Party -> Party -> Var -> Type A -> Expr C
ca neg pos x (TyCon "->" [s1, s2]) =
  exAbs' y (atype2ctype s1) $
    exLet' z (exApp (exVar x) (ac pos neg y s1)) $
      ca neg pos z s2
  where y = x /./ "y"
        z = x /./ "z"
ca neg pos x (TyCon "-o" [s1, s2]) =
  exLet u createContract $
    exAbs y (atype2ctype s1) $
      exSeq (checkContract u neg "applied one-shot function twice") $
        exLet' z (exApp (exVar x) (ac pos neg y s1)) $
          ca neg pos z s2
  where u = x /./ "u"
        y = x /./ "y"
        z = x /./ "z"
ca neg pos x (TyAll tv t) =
  exTAbs' tv' $
    exLet' u (exTApp (exVar x) (TyVar tv')) $
      ca neg pos u t
  where tv' = TV (tvname tv /./ "v") Qu
        u   = tvname tv /./ "u"
ca neg _   x ta | qualifier ta <: Qu = exVar x
                | otherwise =
  exLet' u createContract $
    exAbs' y tyUnit $
      exSeq (checkContract u neg "passed one-shot value twice") $
        exVar x
  where u = x /./ "u"
        y = x /./ "y"

-- Given negative and positive blame labels, the name of a C
-- language variable we wish to protect, and the A type the variable
-- should have, generates an expression that projects that variable.
--
-- This wrapper protects the negative party and may blame the
-- positive party.
ac :: Party -> Party -> Var -> Type A -> Expr C
ac neg pos x (TyCon n [s1, s2]) | n `elem` funtypes =
  exAbs' y (atype2ctype s1) $
    exLet' z (exApp (exVar x) (ca pos neg y s1)) $
      ac neg pos z s2
  where y = x /./ "y"
        z = x /./ "z"
ac neg pos x (TyAll tv t) =
  exTAbs' tv' $
    exLet' u (exTApp (exVar x) (TyVar tv')) $
      ac neg pos u t
  where tv' = TV (tvname tv /./ "v") Qu
        u   = tvname tv /./ "u"
ac _   _   x ta | qualifier ta <: Qu = exVar x
                | otherwise = exApp (exVar x) exUnit

-- Given negative and positive blame labels, the name of a C
-- language variable we wish to protect, and the C type the variable
-- should have, generates an expression that projects that C modules
-- from each other.  This only generates coercions when the C type
-- has an A type embedded in it.
--
-- This isn't necessary for soundness, but is necessary to place
-- the blame on the correct C module.
--
-- This wrapper protects either party and may blame either party.
cc :: Party -> Party -> Var -> Type C -> Expr C
cc neg pos x (TyCon "->" [s1, s2]) =
  exAbs' y s1 $
    exLet' z (exApp (exVar x) (cc pos neg y s1)) $
      cc neg pos z s2
  where y = x /./ "y"
        z = x /./ "z"
cc neg _   x (TyA ta) | not (qualifier ta <: Qu) =
  exLet' u createContract $
    exAbs' y tyUnit $
      exSeq (checkContract u neg "passed one-shot value twice") $
        exApp (exVar x) exUnit
  where y = x /./ "y"
        u = x /./ "u"
cc neg pos x (TyAll tv t) =
  exTAbs' tv' $
    exLet' u (exTApp (exVar x) (TyVar tv')) $
      cc neg pos u t
  where tv' = TV (tvname tv /./ "v") Qu
        u   = tvname tv /./ "u"
cc _   _   x _ = exVar x

-- Generate an expression to create an initial (blessed) cell
createContract :: Expr C
createContract = exApp (exTApp (exVar (Var "#ref"))
                               (tyUnit `tyArr` tyUnit))
                       (exAbs (Var "_") tyUnit exUnit)

-- Given a variable containing a reference cell, generate code
-- to check it
checkContract :: Var -> Party -> String -> Expr C
checkContract x (Party who) what =
  exLet f (exApp (exTApp (exVar (Var "#modify"))
                         (tyUnit `tyArr` tyUnit))
                 (exVar x `exPair` blameFun (show who) what)) $
    exApp (exVar f) exUnit
  where f = x /./ "f"

-- Generate a function that raises blame
blameFun :: String -> String -> Expr C
blameFun who what =
  exAbs (Var "_") tyUnit $
    exApp (exApp (exVar (Var "#blame"))
                 (exStr who))
          (exStr what)

-- Sort of a gensym -- safe in the context where we use it.
(/./)      :: Var -> String -> Var
Var v /./ s = Var (v ++ '#' : s)

(/^/)      :: Party -> String -> Party
Party (Var v) /^/ s = Party (Var (v ++ s))

tyUnit :: Type C
tyUnit  = tyGround "unit"

exUnit :: Expr C
exUnit  = exCon "()"

----
---- To make our code cleaner, we have two constructors
---- that perform trivial reduction on the fly:
----

-- Constructs a let expression, but with a special case:
--
--   exLet' x e (exVar x)  ==  e
--
-- This is always safe to do.
exLet' :: Var -> Expr w -> Expr w -> Expr w
exLet' v e1 e2 = case expr' e2 of
  ExVar v' | v == v' -> e1
  _                  -> exLet v e1 e2

-- Constructs a lambda expression, but with a special case:
--
--    exAbs' x t (exApp (exVar f) (exVar x))  ==  exVar f
--
-- This eta-contraction is always safe, because f has no effect
exAbs' :: Var -> Type w -> Expr w -> Expr w
exAbs' x t e = case expr' e of
  ExApp e1 e2 -> case (expr' e1, expr' e2) of
    (ExVar f, ExVar x') |
      x == x' && x /= f -> exVar f
    _                   -> exAbs x t e
  _           -> exAbs x t e

-- Construct a type-lambda expression, but with a special case:
--
--   exTAbs' tv (exTApp (exVar f) tv)  ==  exVar f
--
-- This should always be safe, because f has no effect
exTAbs' :: TyVar -> Expr w -> Expr w
exTAbs' tv e = case expr' e of
  ExTApp e1 t2 -> case (expr' e1, t2) of
    (ExVar f, TyVar tv') |
      tv == tv'  -> exVar f
    _            -> exTAbs tv e
  _            -> exTAbs tv e

