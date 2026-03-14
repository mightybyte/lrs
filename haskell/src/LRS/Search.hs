module LRS.Search
  ( RepeatedSubstring(..)
  , findTopRepeated
  ) where

import Data.List (mapAccumR, sortBy)
import Data.Ord (Down(..))
import qualified Data.HashSet as HS
import qualified Data.Text as T
import qualified Data.Vector.Unboxed as V

import LRS.SuffixArray (SuffixArray(..))

data RepeatedSubstring = RepeatedSubstring
  { _rs_substring :: !T.Text
  , _rs_length    :: !Int
  , _rs_count     :: !Int   -- ^ Number of occurrences
  } deriving (Show)

-- | A lightweight candidate: just integers, no string allocation yet.
data Candidate = Candidate
  { _ca_depth     :: !Int
  , _ca_startRank :: !Int
  , _ca_count     :: !Int
  }

-- | Find the top N longest repeated substrings with at least the given
-- minimum length.  Uses a stack-based O(n) scan of the LCP array to
-- enumerate all LCP intervals (each corresponding to an internal node
-- in the conceptual suffix tree).
findTopRepeated :: Int -> Int -> SuffixArray -> [RepeatedSubstring]
findTopRepeated topN minLen (SuffixArray txt sa lcp) =
    let distToSentinel = buildDistToSentinel txt
    in  take topN
      $ dedup
      $ sortBy (\a b -> compare (Down (_rs_length a)) (Down (_rs_length b)))
      $ map (materialise txt sa)
      $ take (topN * 50)
      $ collapseTowers sa
      $ sortBy (\a b -> compare (Down (_ca_depth a)) (Down (_ca_depth b)))
      $ filter (noSentinel sa distToSentinel)
      $ collectLcpIntervals sa lcp minLen

-- | Materialise a candidate into a full result.
materialise :: T.Text -> V.Vector Int -> Candidate -> RepeatedSubstring
materialise txt sa (Candidate depth startRank count) =
  let suffixIdx = sa V.! startRank
      substr = T.take depth (T.drop suffixIdx txt)
  in RepeatedSubstring substr depth count

-- | Precompute distance from each position to the next sentinel character.
-- distToSentinel[i] = number of chars from position i to the next '\0'.
buildDistToSentinel :: T.Text -> V.Vector Int
buildDistToSentinel txt = V.fromList dists
  where
    (_, dists) = mapAccumR step 0 (T.unpack txt)
    step d c = let d' = if c == '\0' then 0 else d
               in (d' + 1, d')

-- | Check whether a candidate's representative suffix crosses a sentinel.
noSentinel :: V.Vector Int -> V.Vector Int -> Candidate -> Bool
noSentinel sa distToSentinel c =
    let pos = sa V.! _ca_startRank c
    in  distToSentinel V.! pos >= _ca_depth c

-- | Collapse towers of candidates from the same repeated block.
-- A block of length L generates candidates at depths L, L-1, ..., where
-- each step shifts the representative suffix position right by 1 while
-- reducing depth by 1, keeping the end position (pos + depth) constant.
-- Keying on (end_position, count) collapses these towers in O(n).
-- Since input is sorted by depth descending, the first candidate seen
-- for each key is the longest.
collapseTowers :: V.Vector Int -> [Candidate] -> [Candidate]
collapseTowers sa = go HS.empty
  where
    go _ [] = []
    go seen (c:cs)
      | HS.member key seen = go seen cs
      | otherwise          = c : go (HS.insert key seen) cs
      where
        pos = sa V.! _ca_startRank c
        key = (pos + _ca_depth c, _ca_count c)

-- | Stack-based O(n) enumeration of all LCP intervals.
-- Each interval corresponds to an internal node in the conceptual suffix tree
-- with a specific string depth and occurrence count.
--
-- Stack entries are (depth, leftBound).
collectLcpIntervals :: V.Vector Int -> V.Vector Int -> Int -> [Candidate]
collectLcpIntervals _sa lcp minLen = go 1 [] []
  where
    n = V.length lcp

    go :: Int -> [(Int, Int)] -> [Candidate] -> [Candidate]
    go !i stack acc
      | i > n = flush stack acc
      | otherwise =
          let curLcp = if i < n then lcp V.! i else 0
              (stack', leftBound, acc') = popAbove stack curLcp (i - 1) i acc
              stack'' = if curLcp > 0
                        then pushIfNeeded stack' curLcp leftBound
                        else stack'
          in go (i + 1) stack'' acc'

    -- Pop all stack entries with depth > curLcp, emitting candidates.
    -- Returns (remaining_stack, last_popped_left_bound, accumulated_candidates).
    popAbove :: [(Int, Int)] -> Int -> Int -> Int -> [Candidate] -> ([(Int, Int)], Int, [Candidate])
    popAbove [] _curLcp leftBound _i acc = ([], leftBound, acc)
    popAbove stk@((depth, lb):rest) curLcp leftBound i acc
      | depth > curLcp =
          let count = i - lb
              acc' = if depth >= minLen && count >= 2
                     then Candidate depth lb count : acc
                     else acc
          in popAbove rest curLcp lb i acc'
      | otherwise = (stk, leftBound, acc)

    -- Push curLcp if it's greater than the top of the stack.
    pushIfNeeded :: [(Int, Int)] -> Int -> Int -> [(Int, Int)]
    pushIfNeeded [] curLcp leftBound = [(curLcp, leftBound)]
    pushIfNeeded stk@((topDepth, _):_) curLcp leftBound
      | topDepth < curLcp = (curLcp, leftBound) : stk
      | otherwise         = stk

    -- Flush remaining stack entries at the end.
    flush :: [(Int, Int)] -> [Candidate] -> [Candidate]
    flush [] acc = acc
    flush ((depth, lb):rest) acc =
      let count = n - lb
          acc' = if depth >= minLen && count >= 2
                 then Candidate depth lb count : acc
                 else acc
      in flush rest acc'

-- | Remove substrings that are contained within an already-accepted longer
-- result AND have the same or fewer occurrences.  A shorter substring with
-- more occurrences is an independent pattern, not a redundant sub-match.
-- Input must be sorted longest-first.
dedup :: [RepeatedSubstring] -> [RepeatedSubstring]
dedup = go []
  where
    go _ [] = []
    go accepted (r:rs)
      | any (\a -> _rs_substring r `T.isInfixOf` _rs_substring a
                && _rs_count r <= _rs_count a) accepted
        = go accepted rs
      | otherwise
        = r : go (r : accepted) rs
