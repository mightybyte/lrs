module LRS.SuffixArray
  ( SuffixArray(..)
  , buildSuffixArray
  , hashContent
  , loadCache
  , saveCache
  ) where

import Control.Exception (SomeException, try)
import Data.Array.Unboxed (UArray, listArray, (!), bounds)
import Data.Binary (Binary(..))
import qualified Data.Binary as Binary
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Crypto.Hash.SHA256 as SHA256
import Data.List (sortBy)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Vector.Unboxed (Vector)
import qualified Data.Vector.Unboxed as V

-- | A suffix array paired with the original text and LCP array.
-- The suffix array is a permutation of [0..n) sorted by suffix order.
-- The LCP array stores the length of the longest common prefix between
-- consecutive suffixes in sorted order.
data SuffixArray = SuffixArray
  { _sa_text :: !Text
  , _sa_sa   :: !(Vector Int)   -- ^ Suffix array
  , _sa_lcp  :: !(Vector Int)   -- ^ LCP array
  } deriving (Show)

-- | On-disk cache format: content hash + suffix array + LCP array (no text).
data SaCache = SaCache
  { _sac_hash :: !BS.ByteString
  , _sac_sa   :: !(Vector Int)
  , _sac_lcp  :: !(Vector Int)
  }

instance Binary SaCache where
  put (SaCache h sa lcp) = put h >> put (V.toList sa) >> put (V.toList lcp)
  get = do
    h   <- get
    sa  <- V.fromList <$> get
    lcp <- V.fromList <$> get
    return (SaCache h sa lcp)

-- | Compute a SHA-256 hash of the combined text.
hashContent :: Text -> BS.ByteString
hashContent = SHA256.hash . TE.encodeUtf8

-- | Try to load a cached suffix array, validating against the given text.
loadCache :: FilePath -> Text -> IO (Maybe SuffixArray)
loadCache path combinedText = do
  result <- try (Binary.decodeFile path) :: IO (Either SomeException SaCache)
  case result of
    Left _  -> return Nothing
    Right (SaCache cachedHash sa lcp) ->
      let currentHash = hashContent combinedText
          txt' = combinedText <> T.singleton '\0'
      in if cachedHash == currentHash
         then return (Just (SuffixArray txt' sa lcp))
         else return Nothing

-- | Save the suffix array and LCP array with a content hash.
saveCache :: FilePath -> BS.ByteString -> SuffixArray -> IO ()
saveCache path contentHash (SuffixArray _ sa lcp) =
  BL.writeFile path (Binary.encode (SaCache contentHash sa lcp))

-- | Build a suffix array from text using naive O(n^2 log n) construction
-- (sort all suffixes), then compute the LCP array in O(n) using Kasai's
-- algorithm.
buildSuffixArray :: Text -> SuffixArray
buildSuffixArray txt =
  let txt' = txt <> T.singleton '\0'
      chars = T.unpack txt'
      n = length chars
      arr = listArray (0, n - 1) chars :: UArray Int Char
      sa  = V.fromList $ sortBy (compareSuffixes arr n) [0 .. n - 1]
      lcp = kasai arr sa
  in SuffixArray txt' sa lcp

compareSuffixes :: UArray Int Char -> Int -> Int -> Int -> Ordering
compareSuffixes arr n a b = go' a b
  where
    go' !i !j
      | i >= n && j >= n = EQ
      | i >= n            = LT
      | j >= n            = GT
      | arr ! i < arr ! j = LT
      | arr ! i > arr ! j = GT
      | otherwise          = go' (i + 1) (j + 1)

-- | Kasai's algorithm: compute the LCP array in O(n).
-- lcp[i] = length of longest common prefix between sa[i-1] and sa[i].
-- lcp[0] = 0 by convention.
kasai :: UArray Int Char -> Vector Int -> Vector Int
kasai arr sa =
  let n = V.length sa
      rank = V.replicate n 0 V.// [(sa V.! i, i) | i <- [0 .. n - 1]]
      go !i !k !lcpAcc
        | i >= n = lcpAcc
        | rank V.! i == 0 = go (i + 1) 0 lcpAcc
        | otherwise =
            let j = sa V.! (rank V.! i - 1)
                (_, hi) = bounds arr
                !k' = computeLcp arr i j k (hi + 1)
            in go (i + 1) (max 0 (k' - 1)) ((rank V.! i, k') : lcpAcc)
  in V.replicate n 0 V.// go 0 0 []

computeLcp :: UArray Int Char -> Int -> Int -> Int -> Int -> Int
computeLcp arr !i !j !k !n
  | i + k >= n || j + k >= n = k
  | arr ! (i + k) /= arr ! (j + k) = k
  | otherwise = computeLcp arr i j (k + 1) n
