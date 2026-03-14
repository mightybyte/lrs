module LRSSpec (lrsSpec) where

------------------------------------------------------------------------------
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Test.Hspec
------------------------------------------------------------------------------
import           LRS.Search (RepeatedSubstring(..), findTopRepeated)
import           LRS.SuffixTree (buildSuffixTree)
------------------------------------------------------------------------------

lrsSpec :: Spec
lrsSpec = do
  describe "single file with long repeated substring" $ do
    it "finds the repeated DEADBEEF CAFEBABE block" $ do
      txt <- TIO.readFile "test-data/single.txt"
      let tree = buildSuffixTree txt
          results = findTopRepeated 3 2 tree
      case results of
        (top:_) -> do
          _rs_substring top `shouldBe` "DEADBEEF CAFEBABE 0123456789 "
          _rs_length top `shouldBe` 29
          _rs_count top `shouldBe` 2
        [] -> expectationFailure "expected at least one result"

  describe "file with only short repeated substrings" $ do
    it "finds only 2-character repeats" $ do
      txt <- TIO.readFile "test-data/short.txt"
      let tree = buildSuffixTree txt
          results = findTopRepeated 10 2 tree
      results `shouldSatisfy` (not . null)
      results `shouldSatisfy` all (\r -> _rs_length r == 2)
      let subs = map _rs_substring results
      subs `shouldSatisfy` elem "x "
      subs `shouldSatisfy` elem "y "

  describe "long repeated substring across directory hierarchy" $ do
    it "finds the shared line between alpha.txt and gamma.txt" $ do
      let files = [ "test-data/project/src/alpha.txt"
                  , "test-data/project/src/beta.txt"
                  , "test-data/project/lib/gamma.txt"
                  , "test-data/project/lib/delta.txt"
                  ]
      contents <- mapM TIO.readFile files
      let combined = T.intercalate (T.singleton '\0') contents
                  <> T.singleton '\0'
          tree = buildSuffixTree combined
          results = findTopRepeated 3 2 tree
      case results of
        (top:_) -> do
          _rs_length top `shouldBe` 67
          _rs_substring top `shouldSatisfy`
            T.isPrefixOf "The quick brown fox jumped over the lazy dog near the riverbank."
          _rs_count top `shouldBe` 2
        [] -> expectationFailure "expected at least one result"
