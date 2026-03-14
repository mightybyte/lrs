module AppMain (appMain) where

import Control.Monad (filterM, forM, when)
import Data.List (sort)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))

import LRS.Search (RepeatedSubstring(..), findTopRepeated)
import LRS.SuffixArray (SuffixArray, buildSuffixArray, hashContent, loadCache, saveCache)

data Opts = Opts
  { _opts_topN               :: Int
  , _opts_recursive          :: Bool
  , _opts_minLength          :: Int
  , _opts_collapseWhitespace :: Bool
  , _opts_cache              :: Maybe FilePath
  , _opts_paths              :: [FilePath]
  } deriving (Show)

optsParser :: Parser Opts
optsParser = Opts
  <$> option auto
      ( long "top" <> short 'n'
     <> value 10
     <> showDefault
     <> metavar "N"
     <> help "Number of results to show" )
  <*> switch
      ( long "recursive" <> short 'r'
     <> help "Recursively search directories" )
  <*> option auto
      ( long "min-length"
     <> value 2
     <> showDefault
     <> metavar "N"
     <> help "Minimum substring length to report" )
  <*> switch
      ( long "collapse-whitespace"
     <> help "Collapse all whitespace sequences into a single space" )
  <*> optional (strOption
      ( long "cache"
     <> metavar "FILE"
     <> help "Cache the suffix array to FILE for faster subsequent runs" ))
  <*> some (argument str (metavar "PATH..."))

appMain :: IO ()
appMain = do
  opts <- execParser $ info (optsParser <**> helper)
    ( fullDesc
   <> progDesc "Find the longest repeated substrings in files"
   <> header "lrs - longest repeated substring finder" )

  files <- resolveFiles (_opts_recursive opts) (_opts_paths opts)
  when (null files) $ do
    putStrLn "Error: no files found"
    exitFailure

  rawCombined <- readAndCombine files
  let fileIndex = buildFileIndex files rawCombined
      (combined, posMap) = if _opts_collapseWhitespace opts
                           then let (c, m) = collapseWhitespace rawCombined
                                in  (c, Just m)
                           else (rawCombined, Nothing)

  sa <- case _opts_cache opts of
    Just cachePath -> do
      cacheExists <- doesFileExist cachePath
      if cacheExists
        then do
          mCached <- loadCache cachePath combined
          case mCached of
            Just t -> do
              putStrLn $ "Loading cached suffix array from " ++ cachePath
              return t
            Nothing -> do
              putStrLn "Cache stale or corrupt, rebuilding..."
              buildAndCache combined cachePath
        else buildAndCache combined cachePath
    Nothing -> return $! buildSuffixArray combined

  let results0 = findTopRepeated (_opts_topN opts) (_opts_minLength opts) sa
      results1 = if _opts_collapseWhitespace opts
                 then trimResults results0
                 else results0
      results = mapPositions posMap results1

  putStrLn $ "Analyzed " ++ show (length files) ++ " file(s)"
  putStrLn ""

  if null results
    then putStrLn "No repeated substrings found."
    else printResults fileIndex results

readAndCombine :: [FilePath] -> IO T.Text
readAndCombine files = do
  contents <- forM files $ \f -> TIO.readFile f
  return $ T.intercalate (T.singleton '\0') contents <> T.singleton '\0'

trimResults :: [RepeatedSubstring] -> [RepeatedSubstring]
trimResults = dedupBySubstring . map trimOne
  where
    trimOne (RepeatedSubstring s _ c p) =
      let s' = T.strip s
      in  RepeatedSubstring s' (T.length s') c p
    dedupBySubstring = go []
      where
        go _ [] = []
        go seen (r:rs)
          | _rs_substring r `elem` seen = go seen rs
          | otherwise = r : go (_rs_substring r : seen) rs

-- | Map result positions back to original text positions using a position map.
mapPositions :: Maybe [Int] -> [RepeatedSubstring] -> [RepeatedSubstring]
mapPositions Nothing rs = rs
mapPositions (Just pm) rs = map mapOne rs
  where
    mapOne r
      | _rs_position r < length pm = r { _rs_position = pm !! _rs_position r }
      | otherwise = r

collapseWhitespace :: T.Text -> (T.Text, [Int])
collapseWhitespace txt = let (cs, ps) = unzip (go False 0 (T.unpack txt))
                         in  (T.pack cs, ps)
  where
    go _ _ [] = []
    go _ i ('\0':rest) = ('\0', i) : go False (i+1) rest
    go inWs i (c:rest)
      | isWs c    = if inWs then go True (i+1) rest else (' ', i) : go True (i+1) rest
      | otherwise  = (c, i) : go False (i+1) rest
    isWs c = c == ' ' || c == '\t' || c == '\n' || c == '\r'
           || c == '\f' || c == '\v'

-- | An entry mapping a character offset range to a file path and its line offsets.
data FileEntry = FileEntry
  { _fe_start       :: !Int
  , _fe_path        :: !FilePath
  , _fe_lineOffsets :: ![Int]
  }

-- | Build an index mapping character positions in the combined text back to
-- file paths and line numbers.
buildFileIndex :: [FilePath] -> T.Text -> [FileEntry]
buildFileIndex files combined = go 0 files (T.splitOn (T.singleton '\0') combined)
  where
    go _ _ [] = []
    go _ [] _ = []
    go offset (f:fs) (seg:segs)
      | T.null seg = go (offset + 1) (f:fs) segs
      | otherwise  =
          let lineOffs = 0 : [ i + 1 | (i, c) <- zip [0..] (T.unpack seg), c == '\n' ]
          in  FileEntry offset f lineOffs : go (offset + T.length seg + 1) fs segs

-- | Look up the file path and line number for a character position.
lookupLocation :: [FileEntry] -> Int -> (FilePath, Int)
lookupLocation entries pos = case filter (\e -> _fe_start e <= pos) (reverse entries) of
    (e:_) ->
      let localPos = pos - _fe_start e
          line = length (takeWhile (<= localPos) (_fe_lineOffsets e))
      in  (_fe_path e, line)
    [] -> ("<unknown>", 0)

buildAndCache :: T.Text -> FilePath -> IO SuffixArray
buildAndCache combined cachePath = do
  let contentHash = hashContent combined
      !sa = buildSuffixArray combined
  saveCache cachePath contentHash sa
  putStrLn $ "Saved suffix array cache to " ++ cachePath
  return sa

printResults :: [FileEntry] -> [RepeatedSubstring] -> IO ()
printResults fileIndex results = do
  let locations = map (\rs -> let (f, l) = lookupLocation fileIndex (_rs_position rs)
                              in  f ++ ":" ++ show l) results
      locWidth = max 8 (if null locations then 0 else maximum (map length locations))
      totalWidth = 5 + 9 + 9 + 57 + locWidth
  putStrLn $ padR 5 "#" ++ padR 9 "Length" ++ padR 9 "Count" ++ padR 57 "Substring" ++ "Location"
  putStrLn $ replicate totalWidth '-'
  mapM_ printOne (zip3' [1::Int ..] results locations)
  where
    zip3' (a:as') (b:bs) (c:cs) = (a,b,c) : zip3' as' bs cs
    zip3' _ _ _ = []
    printOne (i, rs, loc) =
      putStrLn $ padR 5 (show i)
              ++ padR 9 (show (_rs_length rs))
              ++ padR 9 (show (_rs_count rs))
              ++ padR 57 (formatSubstring 50 (_rs_substring rs))
              ++ loc

padR :: Int -> String -> String
padR n s = s ++ replicate (max 0 (n - length s)) ' '

formatSubstring :: Int -> T.Text -> String
formatSubstring maxLen txt =
  let escaped = concatMap escapeChar (T.unpack txt)
      truncated = if length escaped > maxLen
                  then take maxLen escaped ++ "..."
                  else escaped
  in "\"" ++ truncated ++ "\""
  where
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c    = [c]

resolveFiles :: Bool -> [FilePath] -> IO [FilePath]
resolveFiles recursive paths = fmap concat $ forM paths $ \p -> do
  isFile <- doesFileExist p
  isDir  <- doesDirectoryExist p
  if isFile then return [p]
  else if isDir then
    if recursive then getFilesRecursive p
    else do
      entries <- sort <$> listDirectory p
      filterM doesFileExist (map (p </>) entries)
  else do
    putStrLn $ "Warning: " ++ p ++ " is not a file or directory, skipping"
    return []

getFilesRecursive :: FilePath -> IO [FilePath]
getFilesRecursive dir = do
  entries <- sort <$> listDirectory dir
  let paths = map (dir </>) entries
  files <- filterM doesFileExist paths
  dirs  <- filterM doesDirectoryExist paths
  subFiles <- fmap concat $ forM dirs getFilesRecursive
  return (sort (files ++ subFiles))
