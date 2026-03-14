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
  { _opts_topN      :: Int
  , _opts_recursive :: Bool
  , _opts_minLength :: Int
  , _opts_cache     :: Maybe FilePath
  , _opts_paths     :: [FilePath]
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

  combined <- readAndCombine files

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

  let results = findTopRepeated (_opts_topN opts) (_opts_minLength opts) sa

  putStrLn $ "Analyzed " ++ show (length files) ++ " file(s)"
  putStrLn ""

  if null results
    then putStrLn "No repeated substrings found."
    else printResults results

readAndCombine :: [FilePath] -> IO T.Text
readAndCombine files = do
  contents <- forM files $ \f -> TIO.readFile f
  return $ T.intercalate (T.singleton '\0') contents <> T.singleton '\0'

buildAndCache :: T.Text -> FilePath -> IO SuffixArray
buildAndCache combined cachePath = do
  let contentHash = hashContent combined
      !sa = buildSuffixArray combined
  saveCache cachePath contentHash sa
  putStrLn $ "Saved suffix array cache to " ++ cachePath
  return sa

printResults :: [RepeatedSubstring] -> IO ()
printResults results = do
  putStrLn $ padR 5 "#" ++ padR 9 "Length" ++ padR 9 "Count" ++ "Substring"
  putStrLn $ replicate 72 '-'
  mapM_ printOne (zip [1::Int ..] results)
  where
    printOne (i, rs) =
      putStrLn $ padR 5 (show i)
              ++ padR 9 (show (_rs_length rs))
              ++ padR 9 (show (_rs_count rs))
              ++ formatSubstring 50 (_rs_substring rs)

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
