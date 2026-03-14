module LRS.Search
  ( RepeatedSubstring(..)
  , findTopRepeated
  ) where

import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Ord (Down(..))
import qualified Data.Text as T

import LRS.SuffixTree (SuffixTree(..), STree(..), SEdge(..))

data RepeatedSubstring = RepeatedSubstring
  { _rs_substring :: !T.Text
  , _rs_length    :: !Int
  , _rs_count     :: !Int   -- ^ Number of occurrences (leaf count under this node)
  } deriving (Show)

-- | A candidate from the tree traversal.  Stores only cheap integer metadata;
-- the actual substring is materialised later for just the final winners.
data Candidate = Candidate
  { _ca_depth    :: !Int   -- ^ String depth from root (= substring length)
  , _ca_leafIdx  :: !Int   -- ^ Any leaf index under this node
  , _ca_count    :: !Int   -- ^ Number of leaves (occurrences)
  }

-- | Find the top N longest repeated substrings with at least the given
-- minimum length.  Substrings containing the sentinel character are
-- filtered out.  Results are deduplicated so that substrings contained
-- within a longer result are removed.
--
-- The traversal collects only lightweight integer candidates and keeps
-- Text materialisation until the very end for just the top results.
findTopRepeated :: Int -> Int -> SuffixTree -> [RepeatedSubstring]
findTopRepeated topN minLen (SuffixTree txt tree) =
    take topN
  $ dedup
  $ sortBy (\a b -> compare (Down (_rs_length a)) (Down (_rs_length b)))
  $ filter (\rs -> not (T.any (== '\0') (_rs_substring rs)))
  $ map (materialise txt)
  -- Over-collect to give dedup enough to work with.
  $ take (topN * 4)
  $ sortBy (\a b -> compare (Down (_ca_depth a)) (Down (_ca_depth b)))
  $ thd (analyze minLen 0 tree)

-- | Turn a candidate into a full result by extracting the substring.
materialise :: T.Text -> Candidate -> RepeatedSubstring
materialise txt (Candidate depth leafIdx count) =
  RepeatedSubstring (T.take depth (T.drop leafIdx txt)) depth count

-- | Remove substrings that are contained within an already-accepted longer
-- result.  Input must be sorted longest-first.
dedup :: [RepeatedSubstring] -> [RepeatedSubstring]
dedup = go []
  where
    go _ [] = []
    go accepted (r:rs)
      | any (\a -> _rs_substring r `T.isInfixOf` _rs_substring a) accepted
        = go accepted rs
      | otherwise
        = r : go (r : accepted) rs

-- | Single-pass traversal returning (leaf count, representative leaf index,
-- candidates).  Only emits a candidate when depth >= minLen.
analyze :: Int -> Int -> STree -> (Int, Int, [Candidate])
analyze _ _ (Leaf i) = (1, i, [])
analyze minLen depth (Internal edges) =
  let childResults = map (\(SEdge _ len child) ->
        analyze minLen (depth + len) child) (Map.elems edges)
      !totalLeaves = sum (map fst3 childResults)
      !anyLeaf     = case childResults of
                       ((_, l, _) : _) -> l
                       []              -> 0
      childCands   = concatMap thd childResults
      thisCand     = [ Candidate depth anyLeaf totalLeaves
                     | depth >= minLen ]
  in (totalLeaves, anyLeaf, thisCand ++ childCands)

fst3 :: (a, b, c) -> a
fst3 (a, _, _) = a

thd :: (a, b, c) -> c
thd (_, _, c) = c
