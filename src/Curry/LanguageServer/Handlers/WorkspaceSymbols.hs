module Curry.LanguageServer.Handlers.WorkspaceSymbols (workspaceSymbolHandler) where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import qualified Curry.LanguageServer.Index.Store as I
import Curry.LanguageServer.Monad
import qualified Data.Text as T
import qualified Language.LSP.Server as S
import qualified Language.LSP.Types as J
import qualified Language.LSP.Types.Lens as J
import System.Log.Logger

workspaceSymbolHandler :: S.Handlers LSM
workspaceSymbolHandler = S.requestHandler J.SWorkspaceSymbol $ \req responder -> do
    liftIO $ debugM "cls.workspaceSymbols" "Processing workspace symbols request"
    let query = req ^. J.params . J.query
    store <- getStore
    symbols <- liftIO $ fetchWorkspaceSymbols store $ T.pack query
    let maxSymbols = 150
    responder $ Right $ J.List $ take maxSymbols symbols

fetchWorkspaceSymbols :: I.IndexStore -> T.Text -> IO [J.SymbolInformation]
fetchWorkspaceSymbols store query = do
    debugM "cls.workspaceSymbols" $ "Searching " ++ show (I.storedSymbolCount store) ++ " symbol(s)..."
    let symbols = I.sseSymbol <$> I.storedSymbolsWithPrefix query store
    infoM "cls.workspaceSymbols" $ "Found " ++ show (length symbols) ++ " symbol(s)"
    return symbols
