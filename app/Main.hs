{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import ANSI
import Sos

import Control.Monad
import Data.ByteString        (ByteString)
import Data.Function
import Data.List.NonEmpty     (NonEmpty(..))
import Data.Monoid
import Data.Yaml              (decodeFileEither, prettyPrintParseException)
import Prelude                hiding (FilePath)
import Options.Applicative
import System.Directory
import System.Exit
import System.FilePath
import System.FSNotify
import System.IO
import Text.Regex.TDFA

import qualified Data.ByteString.Char8 as BS
import qualified Data.List.NonEmpty    as NE

version :: String
version = "Steel Overseer 2.0.1"

data Options = Options
  { optTarget   :: FilePath
  , optRCFile   :: FilePath
  , optCommands :: [RawTemplate]
  , optPatterns :: [RawPattern]
  } deriving Show

main :: IO ()
main = execParser opts >>= main'
 where
  opts = info (helper <*> optsParser)
    ( fullDesc
   <> progDesc "A file watcher and development tool."
   <> header version )

  optsParser :: Parser Options
  optsParser = Options
    <$> strArgument
     ( help "Optional file or directory to watch for changes."
       <> metavar "TARGET"
       <> value "."
       <> showDefault )
    <*> strOption
     ( help "Optional rcfile to read patterns and commands from."
       <> long "rcfile"
       <> value ".sosrc"
       <> showDefault )
    <*> many (fmap BS.pack (strOption
      ( long "command"
        <> short 'c'
        <> help "Add command to run on file event."
        <> metavar "COMMAND" )))
    <*> many (fmap BS.pack (strOption
      ( long "pattern"
        <> short 'p'
        <> help "Add pattern to match on file path. Only relevant if the target is a directory. (default: .*)"
        <> metavar "PATTERN" )))

main' :: Options -> IO ()
main' Options{..} = do
  -- Parse .sosrc rules.
  rc_rules <- parseSosrc optRCFile

  -- Parse cli rules, where one rule is created per pattern that executes
  -- each of @optCommands@ sequentially.
  cli_rules <- do
    let ptterns :: [RawPattern]
        ptterns =
          case (rc_rules, optPatterns) of
            -- If there are no commands in .sosrc, and no patterns
            -- specified on the command line, default to ".*"
            ([], []) -> [".*"]
            _ -> optPatterns
    runSos (mapM (`buildRule` optCommands) ptterns)

  (target, rules) <- do
    is_dir  <- doesDirectoryExist optTarget
    is_file <- doesFileExist optTarget
    case (is_dir, is_file) of
      (True, _) -> pure (optTarget, cli_rules ++ rc_rules)
      -- If the target is a single file, completely ignore the .sosrc
      -- commands and the cli commands.
      (_, True) -> do
        rule <- runSos (buildRule (BS.pack optTarget) optCommands)
        pure (takeDirectory optTarget, [rule])
      _ -> do
        putStrLn ("Target " ++ optTarget ++ " is not a file or directory.")
        exitFailure

  putStrLn "Hit Ctrl+C to quit."

  withManager $ \wm -> do
    job_queue <- newJobQueue

    spawnFileWatcherThread wm job_queue target rules

    -- Run jobs forever, only stopping to prompt whether or not to run enqueued
    -- jobs when a job fails. This way, the failing job's output will not be
    -- lost by subsequent jobs' outputs without the user's consent.
    forever $ do
      stepJobQueue job_queue >>= \case
        JobSuccess -> pure ()
        JobFailure -> do
          jobQueueLength job_queue >>= \case
            0 -> pure ()
            n -> do
              putStrLn (yellow (show n ++ " job(s) still pending."))

              hSetBuffering stdin NoBuffering
              continue <- fix (\prompt -> do
                putStr (yellow "Press 'c' to continue, 'p' to print, or 'a' to abort: ")
                hFlush stdout
                (getChar <* putStrLn "") >>= \case
                  'c' -> pure True
                  'a' -> pure False
                  'p' -> do
                    jobs <- jobQueueJobs job_queue
                    forM_ (jobCommands <$> jobs) $
                      (\(c:|cs) -> do
                        putStrLn ("- " ++ c)
                        mapM_ (putStrLn . ("  " ++)) cs)
                    prompt
                  _ -> prompt)
              hSetBuffering stdin LineBuffering

              -- Here, it's possible we initially reported that `n` jobs were
              -- enqueued, but by the time the user decides to abort them, more
              -- were added. Oh well, abort them all.
              unless continue $ do
                n' <- jobQueueLength job_queue
                clearJobQueue job_queue
                putStrLn (red ("Aborted " ++ show n' ++ " job(s)."))


spawnFileWatcherThread :: WatchManager -> JobQueue -> FilePath -> [Rule] -> IO ()
spawnFileWatcherThread wm job_queue target rules = do
  cwd <- getCurrentDirectory

  let eventRelPath :: Event -> FilePath
      eventRelPath event = makeRelative cwd (eventPath event)

      predicate :: Event -> Bool
      predicate event =
        any (\rule -> match (ruleRegex rule) (eventRelPath event)) rules

  _ <- watchTree wm target predicate $ \event -> do
    let path = BS.pack (eventRelPath event)

    commands <- concat <$> mapM (instantiateTemplates path) rules
    when (commands /= [])
      (enqueueJob (showEvent event cwd) (NE.fromList commands) job_queue)

  pure ()
 where
  instantiateTemplates :: ByteString -> Rule -> IO [ShellCommand]
  instantiateTemplates path Rule{..} =
    case match ruleRegex path of
      [] -> pure []
      (captures:_) -> runSos (mapM (instantiateTemplate captures) ruleTemplates)

--------------------------------------------------------------------------------

-- Parse a list of rules from .sosrc.
parseSosrc :: FilePath -> IO [Rule]
parseSosrc sosrc = do
  exists <- doesFileExist sosrc
  if exists
    then
      decodeFileEither sosrc >>= \case
        Left err -> do
          putStrLn ("Error parsing " ++ show sosrc ++ ":\n" ++ prettyPrintParseException err)
          exitFailure
        Right (raw_rules :: [RawRule]) -> do
          rules <- runSos (mapM buildRawRule raw_rules)
          putStrLn (case length raw_rules of
                      1 -> "Found 1 rule in " ++ show sosrc
                      n -> "Found " ++ show n ++ " rules in " ++ show sosrc)
          pure (concat rules)
    else pure []

--------------------------------------------------------------------------------

showEvent :: Event -> FilePath -> String
showEvent (Added fp _)    cwd = "Added: "    ++ makeRelative cwd fp
showEvent (Modified fp _) cwd = "Modified: " ++ makeRelative cwd fp
showEvent (Removed fp _)  cwd = "Removed: "  ++ makeRelative cwd fp
