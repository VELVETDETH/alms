{-# LANGUAGE
      FlexibleInstances
      #-}
module PprClass (
  -- * Documents
  Doc,
  -- * Pretty-printing class
  Ppr(..), IsInfix(..), ListStyle(..),
  -- ** Helpers
  ppr0, ppr1,
  -- ** Context operations
  prec, prec1, descend, atPrec, atDepth,
  askPrec, askDepth,
  -- * Pretty-printing combinators
  (>+>), (>?>), ifEmpty,
  -- * Renderers
  render, renderS, printDoc, printPpr,
  -- ** Instance helpers
  showFromPpr, pprFromShow,
  -- * Re-exports
  module PrettyPrint
) where

import PrettyPrint hiding (Doc(..), render)
import qualified PrettyPrint as P

-- | Context for pretty-printing.
data PprContext
  = PprContext {
      pcPrec  :: !Int,
      pcDepth :: !Int
  }

-- | Default context
pprContext0 :: PprContext
pprContext0  = PprContext {
  pcPrec  = 0,
  pcDepth = -1
}

type Doc = P.Doc PprContext

data ListStyle 
  = ListStyle {
    listStyleBegin, listStyleEnd, listStylePunct :: Doc,
    listStyleDelimitEmpty, listStyleDelimitSingleton :: Bool,
    listStyleJoiner :: [Doc] -> Doc
  }

-- | Class for pretty-printing at different types
--
-- Minimal complete definition is one of:
--
-- * 'pprPrec'
--
-- * 'ppr'
class Ppr p where
  -- | Print current precedence
  ppr     :: p -> Doc
  -- | Print at the specified enclosing precedence
  pprPrec :: Int -> p -> Doc
  -- | Print a list in the default style
  pprList :: [p] -> Doc
  -- | Print a list in the specified style
  pprStyleList :: ListStyle -> [p] -> Doc
  -- | Style for printing lists
  listStyle   :: [p] -> ListStyle
  --
  --
  ppr         = asksD pcPrec . flip pprPrec
  pprPrec p   = prec p . ppr
  pprList xs  = pprStyleList (listStyle xs) xs
  --
  pprStyleList st [] =
    if listStyleDelimitEmpty st
      then listStyleBegin st <> listStyleEnd st
      else empty
  pprStyleList st [x] =
    if listStyleDelimitSingleton st
      then listStyleBegin st <> ppr x <> listStyleEnd st
      else ppr x
  pprStyleList st xs  =
    listStyleBegin st <>
      listStyleJoiner st (punctuate (listStylePunct st) (map ppr xs))
    <> listStyleEnd st
  --
  listStyle _ = ListStyle {
    listStyleBegin            = lparen,
    listStyleEnd              = rparen,
    listStylePunct            = comma,
    listStyleDelimitEmpty     = False,
    listStyleDelimitSingleton = False,
    listStyleJoiner           = fsep
  }

-- | Print at top level.
ppr0      :: Ppr p => p -> Doc
ppr0       = atPrec 0 . ppr

-- | Print at next level.
ppr1      :: Ppr p => p -> Doc
ppr1       = prec1 . ppr

-- | Enter the given precedence level, drawing parentheses if necessary,
--   and count it as a descent in depth as well.
prec :: Int -> Doc -> Doc
prec p doc = descend $ asksD pcPrec $ \p' ->
  if p' > p
    then parens (atPrec (min p 0) doc)
    else atPrec p doc

-- | Go to the next (tigher) precedence level.
prec1 :: Doc -> Doc
prec1  = mapD (\e -> e { pcPrec = pcPrec e + 1 })

-- | Descend a level, elliding if the level counter runs out
descend :: Doc -> Doc
descend doc = askD $ \e ->
  case pcDepth e of
    -1 -> doc
    0  -> text "..."
    k  -> localD e { pcDepth = k - 1 } doc

-- | Set the precedence, but check or draw parentheses
atPrec   :: Int -> Doc -> Doc
atPrec p  = mapD (\e -> e { pcPrec = p })

-- | Set the precedence, but check or draw parentheses
atDepth  :: Int -> Doc -> Doc
atDepth k = mapD (\e -> e { pcDepth = k })

-- | Find out the precedence
askPrec :: (Int -> Doc) -> Doc
askPrec  = asksD pcPrec

-- | Find out the depth
askDepth :: (Int -> Doc) -> Doc
askDepth  = asksD pcDepth

instance Ppr a => Ppr [a] where
  ppr = pprList

instance Ppr a => Ppr (Maybe a) where
  pprPrec _ Nothing  = empty
  pprPrec p (Just a) = pprPrec p a

-- | Class to check if a particular thing will print infix.  Adds
--   an operation to print at the given precedence only if the given
--   thing is infix.  (We use this for printing arrows without too
--   many parens.)
class Ppr a => IsInfix a where
  isInfix  :: a -> Bool
  pprRight :: a -> Doc
  pprRight a =
    if isInfix a
      then ppr a
      else ppr0 a

instance Ppr Int       where ppr = int
instance Ppr Integer   where ppr = integer
instance Ppr Double    where ppr = double

instance Ppr Char where
  ppr            = text . show
  pprStyleList _ = text

instance Ppr (P.Doc PprContext)  where ppr = id
instance Show (P.Doc PprContext) where showsPrec = showFromPpr

-- Render a document in the preferred style, given a string continuation
renderS :: Doc -> ShowS
renderS doc rest = fullRenderIn pprContext0 PageMode 80 1.1 each rest doc
  where each (Chr c) s'  = c:s'
        each (Str s) s'  = s++s'
        each (PStr s) s' = s++s'

-- Render a document in the preferred style
render :: Doc -> String
render doc = renderS doc ""

-- Render and display a document in the preferred style
printDoc :: Doc -> IO ()
printDoc = fullRenderIn pprContext0 PageMode 80 1.1 each (putChar '\n')
  where each (Chr c) io  = putChar c >> io
        each (Str s) io  = putStr s >> io
        each (PStr s) io = putStr s >> io

-- Pretty-print, render and display in the preferred style
printPpr :: Ppr a => a -> IO ()
printPpr = printDoc . ppr

showFromPpr :: Ppr a => Int -> a -> ShowS
showFromPpr p t = renderS (pprPrec p t)

pprFromShow :: Show a => Int -> a -> Doc
pprFromShow p t = text (showsPrec p t "")

--
-- Some indentation operations
--

liftEmpty :: (Doc -> Doc -> Doc) -> Doc -> Doc -> Doc
liftEmpty joiner d1 d2 = askD f where
  f e | isEmptyIn e d1 = d2
      | isEmptyIn e d2 = d1
      | otherwise      = joiner d1 d2

ifEmpty :: Doc -> Doc -> Doc -> Doc
ifEmpty dc dt df = askD $ \e ->
  if isEmptyIn e dc
    then dt
    else df

(>+>) :: Doc -> Doc -> Doc
(>+>) = flip hang 2

(>?>) :: Doc -> Doc -> Doc
(>?>)  = liftEmpty (>+>)

infixr 5 >+>, >?>
