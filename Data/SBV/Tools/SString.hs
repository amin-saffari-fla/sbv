{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Tools.SString
-- Copyright   :  (c) Joel Burget, Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- A collection of string/character utilities, useful when working
-- with symbolic strings. To the extent possible, the functions
-- in this module follow those of "Data.List" and "Data.Char",  so
-- importing qualified is the recommended workflow.
-----------------------------------------------------------------------------

module Data.SBV.Tools.SString (
        -- * Conversion to/from SChar
          ord, chr
        -- * Length
        , length, null
        -- * Deconstructing/Reconstructing
        , head, tail, charToStr, strToStrAt, strToCharAt, (.!!), implode, concat, (.++)
        -- * Membership, inclusion
        , elem, notElem, isInfixOf, isSuffixOf, isPrefixOf
        -- * Substrings
        , take, drop, subStr, replace, indexOf, offsetIndexOf
        -- * Conversion to\/from naturals
        , strToNat, natToStr
        -- * Conversion to upper\/lower case
        , toLower, toUpper
        -- * Converting digits to ints
        , digitToInt
        -- * Recognizers
        , isControl, isPrint, isSpace, isLower, isUpper, isAlpha, isNumber, isAlphaNum, isDigit, isOctDigit, isHexDigit, isLetter, isPunctuation, isSymbol, isSeparator
        -- * Regular Expressions
        , match
        -- ** White space
        , reNewline, reWhitespace, reWhiteSpaceNoNewLine
        -- ** Separators
        , reTab, rePunctuation
        -- ** Digits
        , reDigit, reOctDigit, reHexDigit
        -- ** Numbers
        , reDecimal, reOctal, reHexadecimal
        -- ** Identifiers
        , reIdentifier
        ) where

import Prelude hiding (elem, notElem, head, tail, length, take, drop, concat, null)
import qualified Prelude as P

import Data.SBV.Core.Data
import Data.SBV.Core.Model
import Data.SBV.Utils.Boolean

import qualified Data.Char as C
import Data.List (genericLength, genericIndex, genericDrop, genericTake)
import qualified Data.List as L (tails, isSuffixOf, isPrefixOf, isInfixOf)

-- For doctest use only
--
-- $setup
-- >>> import Data.SBV.Provers.Prover (prove, sat)

-- | The 'ord' of a character, as an 8-bit value.
ord :: SChar -> SWord8
ord c
 | Just cc <- unliteral c
 = let v = C.ord cc
   in if v <= 255 then literal (fromIntegral v)
                  else error $ "SString.ord: Character value out-of 8-bit range: " ++ show (c, v)  -- Can't really happen
 | True
 = SBV $ SVal k $ Right $ cache r
 where k = KBounded False 8
       r st = do SW _ n <- sbvToSW st c
                 return $ SW k n

-- | Conversion from an 8-bit ASCII value to a character.
--
-- >>> prove $ \x -> ord (chr x) .== x
-- Q.E.D.
-- >>> prove $ \x -> chr (ord x) .== x
-- Q.E.D.
chr :: SWord8 -> SChar
chr w
 | Just cw <- unliteral w
 = literal (C.chr (fromIntegral cw))
 | True
 = SBV $ SVal KChar $ Right $ cache r
 where r st = do SW _ n <- sbvToSW st w
                 return $ SW KChar n

-- | Length of a string.
--
-- >>> sat $ \s -> length s .== 2
-- Satisfiable. Model:
--   s0 = "\NUL\NUL" :: String
-- >>> sat $ \s -> length s .< 0
-- Unsatisfiable
-- >>> prove $ \s1 s2 -> length s1 + length s2 .== length (s1 .++ s2)
-- Q.E.D.
length :: SString -> SInteger
length = lift1 StrLen (Just (fromIntegral . P.length))

-- | @`null` s@ is True iff the string is empty
--
-- >>> prove $ \s -> null s <=> length s .== 0
-- Q.E.D.
-- >>> :set -XOverloadedStrings
-- >>> prove $ \s -> null s <=> s .== ""
-- Q.E.D.
null :: SString -> SBool
null s
  | Just cs <- unliteral s
  = literal (P.null cs)
  | True
  = s .== literal ""

-- | @`head`@ returns the head of a string. Unspecified if the string is empty.
--
-- >>> prove $ \c -> head (charToStr c) .== c
-- Q.E.D.
head :: SString -> SChar
head = (`strToCharAt` 0)

-- | @`tail`@ returns the tail of a string. Unspecified if the string is empty.
--
-- >>> prove $ \h s -> tail (charToStr h .++ s) .== s
-- Q.E.D.
-- >>> prove $ \s -> length s .> 0 ==> length (tail s) .== length s - 1
-- Q.E.D.
-- >>> prove $ \s -> bnot (null s) ==> charToStr (head s) .++ tail s .== s
-- Q.E.D.
tail :: SString -> SString
tail s
 | Just (_:cs) <- unliteral s
 = literal cs
 | True
 = subStr s 1 (length s - 1)

-- | @`charToStr` c@ is the string of length 1 that contains the only character
-- whose value is the 8-bit value @c@.
--
-- >>> :set -XOverloadedStrings
-- >>> prove $ \c -> c .== literal 'A' ==> charToStr c .== "A"
-- Q.E.D.
-- >>> prove $ \c -> length (charToStr c) .== 1
-- Q.E.D.
charToStr :: SChar -> SString
charToStr = lift1 StrUnit (Just check)
  where check c
          | C.ord c <= 255 = [c]
          | True           = error $ "SString.charToStr: Character doesn't fit into an SMTLib 8-bit character! Received: " ++ show (c, C.ord c)

-- | @`strToStrAt` s offset@. Substring of length 1 at @offset@ in @s@.
--
-- >>> prove $ \s1 s2 -> strToStrAt (s1 .++ s2) (length s1) .== strToStrAt s2 0
-- Q.E.D.
-- >>> sat $ \s -> length s .>= 2 &&& strToStrAt s 0 ./= strToStrAt s (length s - 1)
-- Satisfiable. Model:
--   s0 = "\NUL\NUL " :: String
strToStrAt :: SString -> SInteger -> SString
strToStrAt s offset = subStr s offset 1

-- | @`strToCharAt` s i@ is the 8-bit value stored at location @i@. Unspecified if
-- index is out of bounds.
--
-- >>> :set -XOverloadedStrings
-- >>> prove $ \i -> i .>= 0 &&& i .<= 4 ==> "AAAAA" `strToCharAt` i .== literal 'A'
-- Q.E.D.
-- >>> prove $ \s i c -> s `strToCharAt` i .== c ==> indexOf s (charToStr c) .<= i
-- Q.E.D.
strToCharAt :: SString -> SInteger -> SChar
strToCharAt s i
  | Just cs <- unliteral s, Just ci <- unliteral i, ci >= 0, ci < genericLength cs, let c = C.ord (cs `genericIndex` ci), c >= 0, c < 256
  = literal (C.chr c)
  | True
  = SBV (SVal w8 (Right (cache (y (s `strToStrAt` i)))))
  where w8      = KBounded False 8
        -- This is trickier than it needs to be, but necessary since there's
        -- no SMTLib function to extract the character from a string. Instead,
        -- we form a singleton string, and assert that it is equivalent to
        -- the extracted value. See <http://github.com/Z3Prover/z3/issues/1302>
        y si st = do c <- internalVariable st w8
                     cs <- newExpr st KString (SBVApp (StrOp StrUnit) [c])
                     let csSBV = SBV (SVal KString (Right (cache (\_ -> return cs))))
                     internalConstraint st Nothing $ unSBV $ csSBV .== si
                     return c

-- | Short cut for 'strToCharAt'
(.!!) :: SString -> SInteger -> SChar
(.!!) = strToCharAt

-- | @`implode` cs@ is the string of length @|cs|@ containing precisely those
-- characters. Note that there is no corresponding function @explode@, since
-- we wouldn't know the length of a symbolic string.
--
-- >>> prove $ \c1 c2 c3 -> length (implode [c1, c2, c3]) .== 3
-- Q.E.D.
-- >>> prove $ \c1 c2 c3 -> map (strToCharAt (implode [c1, c2, c3])) (map literal [0 .. 2]) .== [c1, c2, c3]
-- Q.E.D.
implode :: [SChar] -> SString
implode = foldr ((.++) . charToStr) ""

-- | Concatenate two strings. See also `.++`.
concat :: SString -> SString -> SString
concat x y | isConcretelyEmpty x = y
           | isConcretelyEmpty y = x
           | True                = lift2 StrConcat (Just (++)) x y

-- | Short cut for `concat`.
--
-- >>> :set -XOverloadedStrings
-- >>> sat $ \x y z -> length x .== 5 &&& length y .== 1 &&& x .++ y .++ z .== "Hello world!"
-- Satisfiable. Model:
--   s0 =  "Hello" :: String
--   s1 =      " " :: String
--   s2 = "world!" :: String
infixr 5 .++
(.++) :: SString -> SString -> SString
(.++) = concat

-- | Is the character in the string?
--
-- >>> prove $ \c -> c `elem` charToStr c
-- Q.E.D.
-- >>> :set -XOverloadedStrings
-- >>> prove $ \c -> bnot (c `elem` "")
-- Q.E.D.
elem :: SChar -> SString -> SBool
c `elem` s
 | Just cs <- unliteral s, Just cc <- unliteral c
 = literal (cc `P.elem` cs)
 | Just cs <- unliteral s                            -- If only the second string is concrete, element-wise checking is still much better!
 = bAny (c .==) $ map literal cs
 | True
 = charToStr c `isInfixOf` s

-- | Is the character not in the string?
--
-- >>> prove $ \c s -> c `elem` s <=> bnot (c `notElem` s)
-- Q.E.D.
notElem :: SChar -> SString -> SBool
c `notElem` s = bnot (c `elem` s)

-- | @`isInfixOf` sub s@. Does @s@ contain the substring @sub@?
--
-- >>> prove $ \s1 s2 s3 -> s2 `isInfixOf` (s1 .++ s2 .++ s3)
-- Q.E.D.
-- >>> prove $ \s1 s2 -> s1 `isInfixOf` s2 &&& s2 `isInfixOf` s1 <=> s1 .== s2
-- Q.E.D.
isInfixOf :: SString -> SString -> SBool
sub `isInfixOf` s
  | isConcretelyEmpty sub
  = literal True
  | True
  = lift2 StrContains (Just (flip L.isInfixOf)) s sub -- NB. flip, since `StrContains` takes args in rev order!

-- | @`isPrefixOf` pre s@. Is @pre@ a prefix of @s@?
--
-- >>> prove $ \s1 s2 -> s1 `isPrefixOf` (s1 .++ s2)
-- Q.E.D.
-- >>> prove $ \s1 s2 -> s1 `isPrefixOf` s2 ==> subStr s2 0 (length s1) .== s1
-- Q.E.D.
isPrefixOf :: SString -> SString -> SBool
pre `isPrefixOf` s
  | isConcretelyEmpty pre
  = literal True
  | True
  = lift2 StrPrefixOf (Just L.isPrefixOf) pre s

-- | @`isSuffixOf` suf s@. Is @suf@ a suffix of @s@?
--
-- >>> prove $ \s1 s2 -> s2 `isSuffixOf` (s1 .++ s2)
-- Q.E.D.
-- >>> prove $ \s1 s2 -> s1 `isSuffixOf` s2 ==> subStr s2 (length s2 - length s1) (length s1) .== s1
-- Q.E.D.
isSuffixOf :: SString -> SString -> SBool
suf `isSuffixOf` s
  | isConcretelyEmpty suf
  = literal True
  | True
  = lift2 StrSuffixOf (Just L.isSuffixOf) suf s

-- | @`take` len s@. Corresponds to Haskell's `take` on symbolic-strings.
--
-- >>> prove $ \s i -> i .>= 0 ==> length (take i s) .<= i
-- Q.E.D.
take :: SInteger -> SString -> SString
take i s = ite (i .<= 0)        (literal "")
         $ ite (i .>= length s) s
         $ subStr s 0 i

-- | @`drop` len s@. Corresponds to Haskell's `drop` on symbolic-strings.
--
-- >>> prove $ \s i -> length (drop i s) .<= length s
-- Q.E.D.
-- >>> prove $ \s i -> take i s .++ drop i s .== s
-- Q.E.D.
drop :: SInteger -> SString -> SString
drop i s = ite (i .>= ls) (literal "")
         $ ite (i .<= 0)  s
         $ subStr s i (ls - i)
  where ls = length s

-- | @`subStr` s offset len@ is the substring of @s@ at offset `offset` with length `len`.
-- This function is under-specified when the offset is outside the range of positions in @s@ or @len@
-- is negative or @offset+len@ exceeds the length of @s@. For a friendlier version of this function
-- that acts like Haskell's `take`\/`drop`, see `strTake`\/`strDrop`.
--
-- >>> :set -XOverloadedStrings
-- >>> prove $ \s i -> i .>= 0 &&& i .< length s ==> subStr s 0 i .++ subStr s i (length s - i) .== s
-- Q.E.D.
-- >>> sat  $ \i j -> subStr "hello" i j .== "ell"
-- Satisfiable. Model:
--   s0 = 1 :: Integer
--   s1 = 3 :: Integer
-- >>> sat  $ \i j -> subStr "hell" i j .== "no"
-- Unsatisfiable
subStr :: SString -> SInteger -> SInteger -> SString
subStr s offset len
  | Just c <- unliteral s                    -- a constant string
  , Just o <- unliteral offset               -- a constant offset
  , Just l <- unliteral len                  -- a constant length
  , let lc = genericLength c                 -- length of the string
  , let valid x = x >= 0 && x < lc           -- predicate that checks valid point
  , valid o                                  -- offset is valid
  , l >= 0                                   -- length is not-negative
  , valid $ o + l - 1                        -- we don't overrun
  = literal $ genericTake l $ genericDrop o c
  | True                                     -- either symbolic, or something is out-of-bounds
  = lift3 StrSubstr Nothing s offset len

-- | @`replace` s src dst@. Replace the first occurrence of @src@ by @dst@ in @s@
--
-- >>> prove $ \s -> replace "hello" s "world" .== "world" ==> s .== "hello"
-- Q.E.D.
replace :: SString -> SString -> SString -> SString
replace s src dst
  | Just a <- unliteral s
  , Just b <- unliteral src
  , Just c <- unliteral dst
  = literal $ walk a b c
  | True
  = lift3 StrReplace Nothing s src dst
  where walk haystack needle newNeedle = go haystack
           where go []       = []
                 go i@(c:cs)
                  | needle `L.isPrefixOf` i = newNeedle ++ genericDrop (genericLength needle :: Integer) i
                  | True                    = c : go cs

-- | @`indexOf` s sub@. Retrieves first position of @sub@ in @s@, @-1@ if there are no occurrences.
-- Equivalent to @`offsetIndexOf` s sub 0@.
--
-- >>> prove $ \s i -> i .> 0 &&& i .< length s ==> indexOf s (subStr s i 1) .<= i
-- Q.E.D.
-- >>> prove $ \s i -> i .> 0 &&& i .< length s ==> indexOf s (subStr s i 1) .== i
-- Falsifiable. Counter-example:
--   s0 = "\NUL\NUL\NUL" :: String
--   s1 =              2 :: Integer
indexOf :: SString -> SString -> SInteger
indexOf s sub = offsetIndexOf s sub 0

-- | @`offsetIndexOf` s sub offset@. Retrieves first position of @sub@ at or
-- after @offset@ in @s@, @-1@ if there are no occurrences.
--
-- >>> prove $ \s sub -> offsetIndexOf s sub 0 .== indexOf s sub
-- Q.E.D.
-- >>> prove $ \s sub i -> i .>= length s &&& length sub .> 0 ==> offsetIndexOf s sub i .== -1
-- Q.E.D.
offsetIndexOf :: SString -> SString -> SInteger -> SInteger
offsetIndexOf s sub offset
  | Just c <- unliteral s               -- a constant string
  , Just n <- unliteral sub             -- a constant search pattern
  , Just o <- unliteral offset          -- at a constant offset
  , o >= 0, o < genericLength c         -- offset is good
  = case [i | (i, t) <- zip [o ..] (L.tails (genericDrop o c)), n `L.isPrefixOf` t] of
      (i:_) -> literal i
      _     -> -1
  | True
  = lift3 StrIndexOf Nothing s sub offset

-- | @`strToNat` s@. Retrieve integer encoded by string @s@ (ground rewriting only).
-- Note that by definition this function only works when 's' only contains digits,
-- that is, if it encodes a natural number. Otherwise, it returns '-1'.
-- See <http://cvc4.cs.stanford.edu/wiki/Strings> for details.
--
-- >>> prove $ \s -> let n = strToNat s in n .>= 0 &&& n .< 10 ==> length s .== 1
-- Q.E.D.
strToNat :: SString -> SInteger
strToNat s
 | Just a <- unliteral s
 = if all C.isDigit a
   then literal (read a)
   else -1
 | True
 = lift1 StrStrToNat Nothing s

-- | @`natToStr` i@. Retrieve string encoded by integer @i@ (ground rewriting only).
-- Again, only naturals are supported, any input that is not a natural number
-- produces empty string, even though we take an integer as an argument.
-- See <http://cvc4.cs.stanford.edu/wiki/Strings> for details.
--
-- >>> prove $ \i -> length (natToStr i) .== 3 ==> i .<= 999
-- Q.E.D.
natToStr :: SInteger -> SString
natToStr i
 | Just v <- unliteral i
 = literal $ if v >= 0 then show v else ""
 | True
 = lift1 StrNatToStr Nothing i

-- | Convert to lower-case.
--
-- >>> prove $ \c -> toLower (toLower c) .== toLower c
-- Q.E.D.
-- >>> prove $ \c -> isLower c ==> toLower (toUpper c) .== c
-- Q.E.D.
toLower :: SChar -> SChar
toLower c = ite (isUpper c) (chr (ord c + 32)) c

-- | Convert to upper-case. N.B. There are three special cases!
--
--   * The character \223 is special. It corresponds to the German Eszett, it is considered lower-case,
--     and furthermore it's upper-case maps back to itself within our character-set. So, we leave it
--     untouched.
--
--   * The character \181 maps to upper-case \924, which is beyond our character set. We leave it
--     untouched. (This is the A with an acute accent.)
--
--   * The character \255 maps to upper-case \376, which is beyond our character set. We leave it
--     untouched. (This is the non-breaking space character.)
--
-- >>> prove $ \c -> toUpper (toUpper c) .== toUpper c
-- Q.E.D.
-- >>> prove $ \c -> isUpper c ==> toUpper (toLower c) .== c
-- Q.E.D.
toUpper :: SChar -> SChar
toUpper c = ite (isLower c &&& c `notElem` "\181\223\255") (chr (ord c - 32)) c

-- | Convert a digit to an integer. Works for hexadecimal digits too. If the input isn't a digit,
-- then return -1.
--
-- >>> prove $ \c -> isDigit c ||| isHexDigit c ==> digitToInt c .>= 0 &&& digitToInt c .<= 15
-- Q.E.D.
-- >>> prove $ \c -> bnot (isDigit c ||| isHexDigit c) ==> digitToInt c .== -1
-- Q.E.D.
digitToInt :: SChar -> SInteger
digitToInt c = ite (uc `elem` "0123456789") (sFromIntegral (o - ord (literal '0')))
             $ ite (uc `elem` "ABCDEF")     (sFromIntegral (o - ord (literal 'A') + 10))
             $ -1
  where uc = toUpper c
        o  = ord uc

-- | Is this a control character? Control characters are essentially the non-printing characters.
isControl :: SChar -> SBool
isControl = (`elem` controls)
  where controls = "\NUL\SOH\STX\ETX\EOT\ENQ\ACK\a\b\t\n\v\f\r\SO\SI\DLE\DC1\DC2\DC3\DC4\NAK\SYN\ETB\CAN\EM\SUB\ESC\FS\GS\RS\US\DEL\128\129\130\131\132\133\134\135\136\137\138\139\140\141\142\143\144\145\146\147\148\149\150\151\152\153\154\155\156\157\158\159"

-- | Is this a printable character? Essentially the complement of 'isControl', with one
-- exception. The Latin-1 character \173 is neither control nor printable. Go figure.
--
-- >>> prove $ \c -> c .== literal '\173' ||| isControl c <=> bnot (isPrint c)
-- Q.E.D.
isPrint :: SChar -> SBool
isPrint c = c ./= literal '\173' &&& bnot (isControl c)

-- | Is this white-space? That is, one of "\t\n\v\f\r \160".
isSpace :: SChar -> SBool
isSpace = (`elem` spaces)
  where spaces = "\t\n\v\f\r \160"

-- | Is this a lower-case character?
--
-- >>> prove $ \c -> isUpper c ==> isLower (toLower c)
-- Q.E.D.
isLower :: SChar -> SBool
isLower = (`elem` lower)
  where lower = "abcdefghijklmnopqrstuvwxyz\181\223\224\225\226\227\228\229\230\231\232\233\234\235\236\237\238\239\240\241\242\243\244\245\246\248\249\250\251\252\253\254\255"

-- | Is this an upper-case character?
--
-- >>> prove $ \c -> bnot (isLower c &&& isUpper c)
-- Q.E.D.
isUpper :: SChar -> SBool
isUpper = (`elem` upper)
  where upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\192\193\194\195\196\197\198\199\200\201\202\203\204\205\206\207\208\209\210\211\212\213\214\216\217\218\219\220\221\222"

-- | Is this an alphabet character? That is lower-case, upper-case and title-case letters, plus letters of caseless scripts and modifiers letters.
isAlpha :: SChar -> SBool
isAlpha = (`elem` alpha)
  where alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz\170\181\186\192\193\194\195\196\197\198\199\200\201\202\203\204\205\206\207\208\209\210\211\212\213\214\216\217\218\219\220\221\222\223\224\225\226\227\228\229\230\231\232\233\234\235\236\237\238\239\240\241\242\243\244\245\246\248\249\250\251\252\253\254\255"

-- | Is this a number character? Note that this set contains not only the digits, but also
-- the codes for a few numeric looking characters like 1/2 etc. Use 'isDigit' for the digits @0@ through @9@.
isNumber :: SChar -> SBool
isNumber = (`elem` "0123456789\178\179\185\188\189\190")

-- | Is this an 'isAlpha' or 'isNumber'.
--
-- >>> prove $ \c -> isAlphaNum c <=> isAlpha c ||| isNumber c
-- Q.E.D.
isAlphaNum :: SChar -> SBool
isAlphaNum c = isAlpha c ||| isNumber c

-- | Is this an ASCII digit, i.e., one of @0@..@9@. Note that this is a subset of 'isNumber'
--
-- >>> prove $ \c -> isDigit c ==> isNumber c
-- Q.E.D.
isDigit :: SChar -> SBool
isDigit = (`elem` "0123456789")

-- | Is this an Octal digit, i.e., one of @0@..@7@.
--
-- >>> prove $ \c -> isOctDigit c ==> isDigit c
-- Q.E.D.
isOctDigit :: SChar -> SBool
isOctDigit = (`elem` "01234567")

-- | Is this a Hex digit, i.e, one of @0@..@9@, @a@..@f@, @A@..@F@.
--
-- >>> prove $ \c -> isHexDigit c ==> isAlphaNum c
-- Q.E.D.
isHexDigit :: SChar -> SBool
isHexDigit = (`elem` "0123456789abcdefABCDEF")

-- | Is this an alphabet character. Note that this function is equivalent to 'isAlpha'.
--
-- >>> prove $ \c -> isLetter c <=> isAlpha c
-- Q.E.D.
isLetter :: SChar -> SBool
isLetter = isAlpha

-- | Is this a punctuation mark?
isPunctuation :: SChar -> SBool
isPunctuation = (`elem` "!\"#%&'()*,-./:;?@[\\]_{}\161\167\171\182\183\187\191")

-- | Is this a symbol?
isSymbol :: SChar -> SBool
isSymbol = (`elem` "$+<=>^`|~\162\163\164\165\166\168\169\172\174\175\176\177\180\184\215\247")

-- | Is this a separator?
--
-- >>> prove $ \c -> isSeparator c ==> isSpace c
-- Q.E.D.
isSeparator :: SChar -> SBool
isSeparator = (`elem` " \160")

-- | @`match` s r@ checks whether @s@ is in the language generated by @r@.
-- TODO: Currently SBV does *not* optimize this call if @s@ is concrete, but
-- rather directly defers down to the solver. We might want to perform the
-- operation on the Haskell side for performance reasons, should this become
-- important.
--
-- For instance, you can generate valid-looking phone numbers like this:
--
-- > let dig09 = RE_Range '0' '9'
-- > let dig19 = RE_Range '1' '9'
-- > let pre   = dig19 `RE_Conc` RE_Loop 2 2 dig09
-- > let post  = dig19 `RE_Conc` RE_Loop 3 3 dig09
-- > let phone = pre `RE_Conc` RE_Literal "-" `RE_Conc` post
-- > sat (`match` phone)
-- > Satisfiable. Model:
-- >   s0 = "222-2248" :: String
--
-- >>> :set -XOverloadedStrings
-- >>> prove $ \s -> match s (RE_Literal "hello") <=> s .== "hello"
-- Q.E.D.
-- >>> prove $ \s -> match s (RE_Loop 2 5 (RE_Literal "xyz")) ==> length s .>= 6
-- Q.E.D.
-- >>> prove $ \s -> match s (RE_Loop 2 5 (RE_Literal "xyz")) ==> length s .<= 15
-- Q.E.D.
-- >>> prove $ \s -> match s (RE_Loop 2 5 (RE_Literal "xyz")) ==> length s .>= 7
-- Falsifiable. Counter-example:
--   s0 = "xyzxyz" :: String
match :: SString -> SRegExp -> SBool
match s r = lift1 (StrInRe r) opt s
  where -- TODO: Replace this with a function that concretely evaluates the string against the
        -- reg-exp, possible future work. But probably there isn't enough ROI.
        opt :: Maybe (String -> Bool)
        opt = Nothing


reNewline             :: a
reNewline             = error "reNewline"

reWhitespace          :: a
reWhitespace          = error "reWhitespace"

reWhiteSpaceNoNewLine :: a
reWhiteSpaceNoNewLine = error "reWhiteSpaceNoNewLine"

reTab                 :: a
reTab                 = error "reTab"

rePunctuation         :: a
rePunctuation         = error "rePunctuation"

reDigit               :: a
reDigit               = error "reDigit"

reOctDigit            :: a
reOctDigit            = error "reOctDigit"

reHexDigit            :: a
reHexDigit            = error "reHexDigit"

reDecimal             :: a
reDecimal             = error "reDecimal"

reOctal               :: a
reOctal               = error "reOctal"

reHexadecimal         :: a
reHexadecimal         = error "reHexadecimal"

reIdentifier          :: a
reIdentifier          = error "reIdentifier"

-- | Lift a unary operator over strings.
lift1 :: forall a b. (SymWord a, SymWord b) => StrOp -> Maybe (a -> b) -> SBV a -> SBV b
lift1 w mbOp a
  | Just cv <- concEval1 mbOp a
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k = kindOf (undefined :: b)
        r st = do swa <- sbvToSW st a
                  newExpr st k (SBVApp (StrOp w) [swa])

-- | Lift a binary operator over strings.
lift2 :: forall a b c. (SymWord a, SymWord b, SymWord c) => StrOp -> Maybe (a -> b -> c) -> SBV a -> SBV b -> SBV c
lift2 w mbOp a b
  | Just cv <- concEval2 mbOp a b
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k = kindOf (undefined :: c)
        r st = do swa <- sbvToSW st a
                  swb <- sbvToSW st b
                  newExpr st k (SBVApp (StrOp w) [swa, swb])

-- | Lift a ternary operator over strings.
lift3 :: forall a b c d. (SymWord a, SymWord b, SymWord c, SymWord d) => StrOp -> Maybe (a -> b -> c -> d) -> SBV a -> SBV b -> SBV c -> SBV d
lift3 w mbOp a b c
  | Just cv <- concEval3 mbOp a b c
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k = kindOf (undefined :: d)
        r st = do swa <- sbvToSW st a
                  swb <- sbvToSW st b
                  swc <- sbvToSW st c
                  newExpr st k (SBVApp (StrOp w) [swa, swb, swc])

-- | Concrete evaluation for unary ops
concEval1 :: (SymWord a, SymWord b) => Maybe (a -> b) -> SBV a -> Maybe (SBV b)
concEval1 mbOp a = literal <$> (mbOp <*> unliteral a)

-- | Concrete evaluation for binary ops
concEval2 :: (SymWord a, SymWord b, SymWord c) => Maybe (a -> b -> c) -> SBV a -> SBV b -> Maybe (SBV c)
concEval2 mbOp a b = literal <$> (mbOp <*> unliteral a <*> unliteral b)

-- | Concrete evaluation for ternary ops
concEval3 :: (SymWord a, SymWord b, SymWord c, SymWord d) => Maybe (a -> b -> c -> d) -> SBV a -> SBV b -> SBV c -> Maybe (SBV d)
concEval3 mbOp a b c = literal <$> (mbOp <*> unliteral a <*> unliteral b <*> unliteral c)

-- | Is the string concretely known empty?
isConcretelyEmpty :: SString -> Bool
isConcretelyEmpty ss | Just s <- unliteral ss = P.null s
                     | True                   = False
