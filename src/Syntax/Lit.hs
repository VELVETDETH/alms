{-# LANGUAGE
      DeriveDataTypeable,
      TemplateHaskell #-}
module Syntax.Lit (
  Lit(..)
) where

import Syntax.Anti

import Data.Generics (Typeable, Data)

-- | Literals
data Lit
  = LtInt Integer
  | LtStr String
  | LtFloat Double
  | LtAnti Anti
  deriving (Eq, Typeable, Data)