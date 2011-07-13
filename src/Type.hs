-- | The internal representation of types, created by the type checker
--   from the syntactic types in 'AST.Type'.
{-# LANGUAGE
      UnicodeSyntax
    #-}
module Type (
  module Type.ArrowAnnotations,
  module Type.Internal,
  module Type.Recursive,
  module Type.Reduce,
  module Type.Subst,
  module Type.Syntax,
  module Type.TyVar,
) where

import Type.ArrowAnnotations
import Type.Internal
import Type.Recursive (standardizeMus)
import Type.Reduce
import Type.Subst
import Type.Syntax
import Type.TyVar
