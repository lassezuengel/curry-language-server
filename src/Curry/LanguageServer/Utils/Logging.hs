{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, FlexibleContexts #-}
module Curry.LanguageServer.Utils.Logging
    ( logAt, showAt
    , errorM, warnM, infoM, debugM
    ) where

import Colog.Core (Severity (..), WithSeverity (..), (<&))
import Control.Monad (when)
import Curry.LanguageServer.Config (Config (..), LogLevel (..))
import qualified Data.Text as T
import Language.LSP.Logging (logToLogMessage, logToShowMessage)
import Language.LSP.Server (MonadLsp, getConfig)

-- | Logs a message to the output console (window/logMessage).
logAt :: MonadLsp Config m => Severity -> T.Text -> m ()
logAt sev msg = do
    cfg <- getConfig
    when (sev >= cfg.logLevel.severity) $
        logToLogMessage <& WithSeverity msg sev

-- | Presents a log message in a notification to the user (window/showMessage).
showAt :: MonadLsp Config m => Severity -> T.Text -> m ()
showAt sev msg = logToShowMessage <& WithSeverity msg sev

-- | Logs a message at the error level. This presents an error notification to the user.
errorM :: MonadLsp Config m => T.Text -> m ()
errorM = showAt Error

-- | Logs a message at the warning level.
warnM :: MonadLsp Config m => T.Text -> m ()
warnM = logAt Warning

-- | Logs a message at the info level.
infoM :: MonadLsp Config m => T.Text -> m ()
infoM = logAt Info

-- | Logs a message at the debug level.
debugM :: MonadLsp Config m => T.Text -> m ()
-- TODO: Remove [Debug] prefix once https://github.com/microsoft/vscode-languageserver-node/issues/1255
--       is resolved and upstreamed to haskell/lsp
debugM t = logAt Debug $ "[Debug] " <> t
