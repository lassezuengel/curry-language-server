{-# LANGUAGE NumericUnderscores #-}

module Curry.LanguageServer.CPM.Process
    ( invokeCPM
    ) where

import Control.Exception (try, IOException)
import Control.Monad (when, join)
import Control.Monad.Error.Class (MonadError(..))
import Curry.LanguageServer.CPM.Monad (cpmm, runCPMM, CPMM)
import Curry.LanguageServer.Utils.General (replaceString)
import Data.Either.Combinators (mapLeft)
import Data.Either.Extra (maybeToEither)
import System.Exit (ExitCode (..))
import System.Process (readCreateProcessWithExitCode, shell, CreateProcess(cwd))
import System.Timeout (timeout)

-- | Invokes the Curry Package Manager executable with the specified args.
invokeCPM :: FilePath -> [String] -> FilePath -> CPMM String
invokeCPM dir args cpmPath = cpmm $ fmap (join . mapLeft errMessage) $ (try :: IO a -> IO (Either IOException a)) $ runCPMM $ do
    let action = readCreateProcessWithExitCode procOpts ""

    (exitCode, out, err) <- cpmm $ maybeToEither "CPM timed out!" <$> timeout microsecs action
    when (exitCode /= ExitSuccess) $ throwError err

    return out
    where errMessage e = "Please make sure that '" <> cpmPath <> "' exists or is on your PATH! Error: " ++ replaceString "\n" " " (show e)
          procOpts = (shell $ unwords $ cpmPath : args) { cwd = Just dir }
          microsecs = 20_000_000
