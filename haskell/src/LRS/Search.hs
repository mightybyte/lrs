module LRS.Search
  ( RepeatedSubstring(..)
  , findTopRepeated
  ) where

import Data.List (sortBy)
import Data.Ord (Down(..))
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
    take topN
  $ dedup
  $ sortBy (\a b -> compare (Down (_rs_length a)) (Down (_rs_length b)))
  $ filter (\rs -> not (T.any (== '\0') (_rs_substring rs)))
  $ map (materialise txt sa)
  $ take (topN * 4)
  $ prededupCandidates sa
  $ sortBy (\a b -> compare (Down (_ca_depth a)) (Down (_ca_depth b)))
  $ collectLcpIntervals sa lcp minLen

-- | Materialise a candidate into a full result.
materialise :: T.Text -> V.Vector Int -> Candidate -> RepeatedSubstring
materialise txt sa (Candidate depth startRank count) =
  let suffixIdx = sa V.! startRank
      substr = T.take depth (T.drop suffixIdx txt)
  in RepeatedSubstring substr depth count

-- | Pre-dedup candidates using suffix positions to collapse "towers" of
-- near-identical candidates from the same repeated block.
--
-- A repeated block of length L generates ~L candidates at depths L, L-1, ...
-- all from overlapping text regions.  We detect this cheaply: a candidate is
-- dominated if an already-accepted candidate has a greater depth, at least as
-- many occurrences, and its text region covers the current candidate's
-- representative suffix position.
--
-- Input must be sorted by depth descending.
prededupCandidates :: V.Vector Int -> [Candidate] -> [Candidate]
prededupCandidates sa = go []
  where
    -- accepted entries: (textPosition, depth, count)
    go _ [] = []
    go accepted (c:cs)
      | dominated = go accepted cs
      | otherwise = c : go ((pos, _ca_depth c, _ca_count c) : accepted) cs
      where
        pos = sa V.! _ca_startRank c
        dominated = any (\(aPos, aDepth, aCount) ->
          pos >= aPos && pos < aPos + aDepth && _ca_count c <= aCount) accepted

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
              (stack', leftBound, acc') = popAbove stack curLcp i acc
              stack'' = if curLcp > 0
                        then pushIfNeeded stack' curLcp leftBound
                        else stack'
          in go (i + 1) stack'' acc'

    -- Pop all stack entries with depth > curLcp, emitting candidates.
    -- Returns (remaining_stack, last_popped_left_bound, accumulated_candidates).
    popAbove :: [(Int, Int)] -> Int -> Int -> [Candidate] -> ([(Int, Int)], Int, [Candidate])
    popAbove [] _curLcp i acc = ([], i - 1, acc)
    popAbove stk@((depth, lb):rest) curLcp i acc
      | depth > curLcp =
          let count = i - lb
              acc' = if depth >= minLen && count >= 2
                     then Candidate depth lb count : acc
                     else acc
          in popAbove rest curLcp i acc'
      | otherwise = (stk, i - 1, acc)

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
