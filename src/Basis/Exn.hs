module Basis.Exn ( entries, ioexn2vexn ) where

import BasisUtils
import Value
import Syntax (LangRepMono(..), ExnId(..),
               eiIOError, eiBlame, eiPatternMatch)

import Control.Exception

-- raiseExn :: Valueable v => String -> Maybe v

entries :: [Entry]
entries = [
    primexn eiIOError      "string",
    primexn eiBlame        "string * string",
    primexn eiPatternMatch "string * string list",
    src "exception[C] Failure of string",

    pfun 1 "raise" -:: "exn -> any"
      -= \exn -> throw (vprj exn :: VExn)
                 :: IO Value,
    pfun 1 "tryC" -: "all 'a. (unit -> 'a) -> (exn, 'a) either"
                  -: "all '<a. (unit -o '<a) -> (exn, '<a) either"
      -= \(VaFun _ f) ->
           tryJust (\e -> if eiLang (exnId e) == LC
                            then Just e
                            else Nothing)
                   (ioexn2vexn (f vaUnit)),
    pfun 1 "tryA" -: ""
                  -: "all '<a. (unit -o '<a) -> (exn, '<a) either"
      -= \(VaFun _ f) -> try (ioexn2vexn (f vaUnit))
                         :: IO (Either VExn Value),

    fun "liftExn" -: ""
                  -: "{exn} -> exn"
      -= (id :: Value -> Value),

    fun "raiseBlame" -:: "string -> string -> unit"
      -= \s1 s2 -> throw VExn {
           exnId    = eiBlame,
           exnParam = Just (vinj (s1 :: String, s2 :: String))
         } :: IO Value
  ]

ioexn2vexn :: IO a -> IO a
ioexn2vexn  = handle $ \e ->
  throw VExn {
    exnId    = eiIOError,
    exnParam = Just (vinj (show (e :: IOException)))
  }