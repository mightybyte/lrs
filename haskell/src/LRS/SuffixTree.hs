module LRS.SuffixTree
  ( SuffixTree(..)
  , STree(..)
  , SEdge(..)
  , buildSuffixTree
  , loadSuffixTree
  , saveSuffixTree
  ) where

import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Binary (Binary(..), putWord8, getWord8)
import qualified Data.Binary as Binary
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | A suffix tree paired with the original text it was built from.
-- Edge labels are stored as (start, length) indices into the text,
-- so the tree is O(n) in size rather than O(n^2).
data SuffixTree = SuffixTree
  { _st_text :: !Text
  , _st_tree :: !STree
  } deriving (Show)

-- | Suffix tree node.
data STree
  = Leaf !Int                    -- ^ Leaf storing the suffix start index
  | Internal !(Map Char SEdge)   -- ^ Internal node with edges keyed by first char
  deriving (Show)

-- | Edge in the suffix tree.  The label is represented as a (start, length)
-- slice into the original text rather than a copied substring.
data SEdge = SEdge
  { _se_start :: !Int    -- ^ Start index in original text
  , _se_len   :: !Int    -- ^ Length of edge label
  , _se_child :: !STree
  } deriving (Show)

instance Binary SuffixTree where
  put (SuffixTree txt tree) = put (TE.encodeUtf8 txt) >> put tree
  get = do
    bs <- get
    tree <- get
    return (SuffixTree (TE.decodeUtf8 bs) tree)

instance Binary STree where
  put (Leaf i) = putWord8 0 >> put i
  put (Internal edges) = putWord8 1 >> put (Map.toAscList edges)
  get = do
    tag <- getWord8
    case tag of
      0 -> Leaf <$> get
      1 -> Internal . Map.fromDistinctAscList <$> get
      _ -> fail "invalid STree tag"

instance Binary SEdge where
  put (SEdge s l child) = put s >> put l >> put child
  get = SEdge <$> get <*> get <*> get

-- | Load a suffix tree from a binary cache file.
loadSuffixTree :: FilePath -> IO SuffixTree
loadSuffixTree = Binary.decodeFile

-- | Save a suffix tree to a binary cache file.
saveSuffixTree :: FilePath -> SuffixTree -> IO ()
saveSuffixTree path st = BL.writeFile path (Binary.encode st)

-- | Build a suffix tree from text using naive O(n^2) construction.
-- A sentinel character (\\0) is appended to ensure all suffixes are unique.
-- Edge labels are stored as index pairs into the original text, keeping
-- the tree O(n) in size.
buildSuffixTree :: Text -> SuffixTree
buildSuffixTree txt =
  let txt' = txt <> T.singleton '\0'
      chars = T.unpack txt'
      n = length chars
      arr = listArray (0, n - 1) chars :: UArray Int Char
      tree = foldl' (\t i -> insertSuffix arr n i t)
                    (Internal Map.empty)
                    [0 .. n - 1]
  in SuffixTree txt' tree

insertSuffix :: UArray Int Char -> Int -> Int -> STree -> STree
insertSuffix arr totalLen suffixStart = go suffixStart (totalLen - suffixStart)
  where
    go !pos !remLen (Internal edges)
      | remLen <= 0 = Internal edges
      | otherwise =
          let c = arr ! pos
          in case Map.lookup c edges of
            Nothing ->
              Internal (Map.insert c (SEdge pos remLen (Leaf suffixStart)) edges)
            Just (SEdge eStart eLen child) ->
              let cpLen = commonPrefixLenArr arr pos remLen eStart eLen
              in if cpLen == eLen
                 then
                   let child' = go (pos + cpLen) (remLen - cpLen) child
                   in Internal (Map.insert c (SEdge eStart eLen child') edges)
                 else
                   let oldStart = eStart + cpLen
                       oldLen   = eLen - cpLen
                       newStart = pos + cpLen
                       newLen   = remLen - cpLen
                       oldEdge  = SEdge oldStart oldLen child
                       splitNode
                         | newLen > 0 =
                             let newLeaf = SEdge newStart newLen (Leaf suffixStart)
                             in Internal (Map.fromList
                                  [ (arr ! oldStart, oldEdge)
                                  , (arr ! newStart, newLeaf) ])
                         | otherwise =
                             Internal (Map.singleton (arr ! oldStart) oldEdge)
                   in Internal (Map.insert c (SEdge eStart cpLen splitNode) edges)
    go _ _ leaf@(Leaf _) = leaf

commonPrefixLenArr :: UArray Int Char -> Int -> Int -> Int -> Int -> Int
commonPrefixLenArr arr pos1 len1 pos2 len2 = go' 0
  where
    !maxLen = min len1 len2
    go' !n
      | n >= maxLen           = n
      | arr ! (pos1 + n) == arr ! (pos2 + n) = go' (n + 1)
      | otherwise             = n
