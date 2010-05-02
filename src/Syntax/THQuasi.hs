{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE
      DeriveDataTypeable,
      TemplateHaskell,
      TypeSynonymInstances #-}
module Syntax.THQuasi (th, ToSyntax(..)) where

import Lexer (lid, uid)
import Util

import Data.Generics (Typeable, Data, everything, mkQ)
import Language.Haskell.TH
import Language.Haskell.TH.Quote
import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Language (haskell)
import Text.ParserCombinators.Parsec.Token

-- | A very limited Haskell abstract syntax for describing both
--   patterns and expressions
data HsAst = HsApp HsAst HsAst
           | HsWild
           | HsVar String
           | HsCon String
           | HsList [HsAst]
           | HsRec String [(String, HsAst)]
           | HsOr HsAst HsAst
           | HsAnti String String
  deriving (Show, Typeable, Data)

-- | The quasiquoter for building TH expressions
th :: QuasiQuoter
th = QuasiQuoter qexp qpat where
  qexp s = parseHs s >>= hsToExpQ
  qpat _ = fail "Quasiquoter `hs' does not support patterns"

-- | Don't allow HsOr to the left of HsApp:
hsApp :: HsAst -> HsAst -> HsAst
hsApp (HsOr hs11 hs12) hs2 = HsOr (hsApp hs11 hs2) (hsApp hs12 hs2)
hsApp hs1 hs2              = HsApp hs1 hs2

-- | Turn AST into a TH expression that constructs a TH expression or
--   pattern, depending on the context.
--
-- In particular, if we parameterize TH types with the type of
-- expression they construct, hsToExpQ has the types:
--
-- @
--   HsAst -> ExpQ (ExpQ ???)
--   HsAst -> ExpQ (PatQ ???)
-- @
hsToExpQ :: HsAst -> ExpQ
hsToExpQ hs0 = do
  name <- newName "underscore"
  expr <- loop (antiName name) hs0
  if hasUnderscore hs0
    then lam1E (varP name) (return expr)
    else return expr
  where
  antiName def "_"  = def
  antiName _   name = mkName name
  loop n hs = case unfoldApp hs of
    (HsAnti v "th", []) -> varE (n v)
    (HsAnti v "", args) -> [| varS $(varE (n v))
                                   $(listE (map (loop n) args)) |]
    (HsAnti v "con", args)
                        -> [| conS $(varE (n v))
                                   $(listE (map (loop n) args)) |]
    (HsVar str, args)   -> [| varS $(litE (stringL str))
                                   $(listE (map (loop n) args)) |]
    (HsCon str, args)   -> [| conS $(litE (stringL str))
                                   $(listE (map (loop n) args)) |]
    (HsWild, [])        -> [| wildS |]
    (HsList hss, [])    -> [| listS $(listE (map (loop n) hss)) |]
    (HsRec con fs, [])  -> [| recS (toName $(litE (stringL con)))
                               $(listE
                                 [ [| fieldS (toName $(litE (stringL lj)))
                                             $(loop n hj) |]
                                 | (lj, hj) <- fs ]) |]
    (HsOr hs1 hs2, [])  -> [| whichS $(loop n hs1) $(loop n hs2) |]
    (HsAnti _ tag, _)   -> fail $ "hs: unrecognized antiquote: " ++ tag
    (op, _:_)           -> fail $ "hs: cannot apply " ++ show op ++ 
                                  " to arguments"
    (HsApp _ _, [])     -> fail $ "hs: impossible!"

-- | Does the given AST contain an antiquote named '_'?  If so, we
--   create an implicit parameter and fill it in there.
hasUnderscore :: HsAst -> Bool
hasUnderscore  = everything (||) $ mkQ False check where
  check (HsAnti "_" _) = True
  check _              = False

-- Allow us to use both Strings and Names where Names are expected
class Show a => ToName a where
  toName     :: a -> Name
  nameIsWild :: a -> Bool
instance ToName Name where
  toName  = id
  nameIsWild = (== "_") . show
instance ToName String where
  toName  = mkName
  nameIsWild = (== "_")

-- Generic constructors for building both patterns and expressions
class ToSyntax b where
  varS   :: ToName a => a -> [Q b] -> Q b
  conS   :: ToName a => a -> [Q b] -> Q b
  listS  :: [Q b] -> Q b
  recS   :: Name -> [Q (Name, b)] -> Q b
  fieldS :: Name -> Q b -> Q (Name, b)
  -- | Return the first argument in expression context and the second
  --   in pattern context
  whichS :: Q b -> Q b -> Q b
  -- | A wild card expression, interpreted as @()@ in expression
  --   (strange, but often right)
  wildS  :: Q b
  -- | Lift data, generically
  dataS  :: Data a => a -> Q b

instance ToSyntax Exp where
  varS      = foldl appE . varE . toName
  conS      = foldl appE . conE . toName
  listS     = listE
  recS      = recConE
  fieldS    = fieldExp
  whichS    = const
  wildS     = conE (mkName "()")
  dataS     = dataToExpQ (const Nothing)

instance ToSyntax Pat where
  varS n []
    | nameIsWild n = wildP
    | otherwise    = varP (toName n)
  varS n _  = fail $ "hs: pattern can't have variable head: " ++ show n
  conS      = conP . toName
  listS     = listP
  recS      = recP
  fieldS    = fieldPat
  whichS    = const id
  wildS     = wildP
  dataS     = dataToPatQ (const Nothing)

-- Figure out the head and arguments of a curried application
unfoldApp :: HsAst -> (HsAst, [HsAst])
unfoldApp (HsApp hs1 hs2) = second (++[hs2]) (unfoldApp hs1)
unfoldApp hs              = (hs, [])

-- Parse a string into a (very limited) Haskell AST that can be
-- interpreted as both expression and pattern
parseHs :: String -> Q HsAst
parseHs str0 = do
  loc <- location
  case parse (start loc) "" str0 of
    Left e    -> fail (show e)
    Right ast -> return ast
  where
  start loc = do
    pos <- getPosition
    setPosition $
      (flip setSourceName) (loc_filename loc) $
      (flip setSourceLine) (fst (loc_start loc)) $
      (flip setSourceColumn) (snd (loc_start loc)) $
      pos
    spaces
    level0 <* eof
  level0 = hsOr <$> level1
                <*> optionMaybe (reservedOp haskell "|" *> level1)
  level1 = foldl1 hsApp <$> many1 level2
  level2 = choice
    [
      HsWild <$  underscore,
      HsVar  <$> lid,
      hsUid  <$> uid
             <*> optionMaybe (braces haskell
                               (sepBy recfield (comma haskell))),
      HsList <$> brackets haskell (sepBy level0 (comma haskell)),
      angles haskell (HsAnti <$> lid_
                             <*> option "" (colon haskell *> 
                                            option "" lid)),
      parens haskell level0
    ]
  recfield = (,) <$> lid <*> (reservedOp haskell "=" *> level0)
  hsUid str (Just rec) = HsRec str rec
  hsUid str Nothing    = HsCon str
  hsOr hs1 Nothing     = hs1
  hsOr hs1 (Just hs2)  = HsOr hs1 hs2
  underscore           = symbol haskell "_"
  lid_                 = lid <|> underscore

-- | Parsec parsers are Applicatives, which lets us write slightly
--   more pleasant, non-monadic-looking parsers
instance Applicative (GenParser a b) where
  pure  = return
  (<*>) = ap
