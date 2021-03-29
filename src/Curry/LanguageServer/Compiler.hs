{-# LANGUAGE LambdaCase #-}
module Curry.LanguageServer.Compiler (
    CompileState (..),
    CompileOutput,
    FileLoader,
    compileCurryFileWithDeps,
    failedCompilation
) where

-- Curry Compiler Libraries + Dependencies
import qualified Curry.Files.Filenames as CFN
import qualified Curry.Files.PathUtils as CF
import qualified Curry.Files.Unlit as CUL
import qualified Curry.Base.Ident as CI
import qualified Curry.Base.Span as CSP
import qualified Curry.Base.SpanInfo as CSPI
import qualified Curry.Base.Message as CM
import Curry.Base.Monad (CYIO, CYT, runCYIO, liftCYM, silent, failMessages, warnMessages)
import qualified Curry.Syntax as CS
import qualified Base.Messages as CBM
import qualified Checks as CC
import qualified CurryDeps as CD
import qualified CompilerEnv as CE
import qualified CondCompile as CNC
import qualified CompilerOpts as CO
import qualified Env.Interface as CEI
import qualified Exports as CEX
import qualified Imports as CIM
import qualified Interfaces as CIF
import qualified Modules as CMD
import qualified Transformations as CT
import qualified Text.PrettyPrint as PP

import Control.Monad (join)
import Control.Monad.Trans.State (StateT (..))
import Control.Monad.Trans.Maybe (MaybeT (..))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Class (modify)
import qualified Curry.LanguageServer.Config as CFG
import Curry.LanguageServer.Utils.General
import Curry.LanguageServer.Utils.Syntax (ModuleAST)
import Data.List (intercalate)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import System.FilePath
import System.Log.Logger

data CompileState = CompileState
    { csWarnings :: [CM.Message]
    , csErrors :: [CM.Message]
    }

instance Semigroup CompileState where
    x <> y = CompileState
        { csWarnings = csWarnings x ++ csWarnings y
        , csErrors = csErrors x ++ csErrors y
        }

instance Monoid CompileState where
    mempty = CompileState
        { csWarnings = []
        , csErrors = []
        }

-- | A custom monad for compilation state as a CYIO-replacement that doesn't track errors in an ExceptT.
type CM = MaybeT (StateT CompileState IO)

runCM :: CM a -> IO (Maybe a, CompileState)
runCM = flip runStateT mempty . runMaybeT

catchCYIO :: CYIO a -> CM (Maybe a)
catchCYIO cyio = liftIO (runCYIO cyio) >>= \case
    Left es       -> do
        modify $ \s -> s { csErrors = csErrors s ++ es }
        return Nothing
    Right (x, ws) -> do
        modify $ \s -> s { csWarnings = csWarnings s ++ ws }
        return $ Just x

liftCYIO :: CYIO a -> CM a
liftCYIO = MaybeT . (join <$>) . runMaybeT . catchCYIO

type CompileOutput = [(FilePath, CE.CompEnv ModuleAST)]

type FileLoader = FilePath -> IO String

-- | Compiles a Curry source file with its dependencies
-- using the given import paths and the given output directory
-- (in which the interface file will be placed). If compilation fails the
-- result will be `Left` and contain error messages.
-- Otherwise it will be `Right` and contain both the parsed AST and
-- warning messages.
compileCurryFileWithDeps :: CFG.Config -> FileLoader -> [FilePath] -> FilePath -> FilePath -> IO (CompileOutput, CompileState)
compileCurryFileWithDeps cfg fl importPaths outDirPath filePath = (fromMaybe mempty <.$>) $ runCM $ do
    let cppOpts = CO.optCppOpts CO.defaultOptions
        cppDefs = M.insert "__PAKCS__" 300 (CO.cppDefinitions cppOpts)
        opts = CO.defaultOptions { CO.optForce = CFG.cfgForceRecompilation cfg
                                 , CO.optImportPaths = importPaths ++ CFG.cfgImportPaths cfg
                                 , CO.optLibraryPaths = CFG.cfgLibraryPaths cfg
                                 , CO.optCppOpts = cppOpts { CO.cppDefinitions = cppDefs }
                                 }
    -- Resolve dependencies
    deps <- liftCYIO $ CD.flatDeps opts filePath
    liftIO $ debugM "cls.compiler" $ "Compiling " ++ takeFileName filePath ++ ", found deps: " ++ intercalate ", " (PP.render . CS.pPrint . fst <$> deps)
    -- Compile the module and its dependencies in topological order
    compileCurryModules opts fl outDirPath deps

-- | Compiles the given list of modules in order.
compileCurryModules :: CO.Options -> FileLoader -> FilePath -> [(CI.ModuleIdent, CD.Source)] -> CM CompileOutput
compileCurryModules opts fl outDirPath deps = case deps of
    [] -> liftCYIO $ failMessages [failMessageFrom "Language Server: No module found"]
    ((m, CD.Source fp ps _is):ds) -> do
        liftIO $ debugM "cls.compiler" $ "Actually compiling " ++ fp
        let opts' = processPragmas opts ps
        output <- compileCurryModule opts' fl outDirPath m fp
        if null ds
            then return output
            else (output <>) <$> compileCurryModules opts fl outDirPath ds
    (_:ds) -> compileCurryModules opts fl outDirPath ds
    where processPragmas :: CO.Options -> [CS.ModulePragma] -> CO.Options
          processPragmas o ps = foldl processLanguagePragma o [e | CS.LanguagePragma _ es <- ps, CS.KnownExtension _ e <- es]
          processLanguagePragma :: CO.Options -> CS.KnownExtension -> CO.Options
          processLanguagePragma o e = case e of
              CS.CPP -> o { CO.optCppOpts = (CO.optCppOpts o) { CO.cppRun = True } }
              _      -> o

-- | Compiles a single module.
compileCurryModule :: CO.Options -> FileLoader -> FilePath -> CI.ModuleIdent -> FilePath -> CM CompileOutput
compileCurryModule opts fl outDirPath m fp = do
    liftIO $ debugM "cls.compiler" $ "Compiling module " ++ takeFileName fp
    -- Parse and check the module
    mdl <- loadAndCheckCurryModule opts fl m fp
    -- Generate and store an on-disk interface file
    mdl' <- CC.expandExports opts mdl
    let interf = uncurry CEX.exportInterface $ CT.qual mdl'
        interfFilePath = outDirPath </> CFN.interfName (CFN.moduleNameToFile m)
        generated = PP.render $ CS.pPrint interf
    liftIO $ debugM "cls.compiler" $ "Writing interface file to " ++ interfFilePath
    liftIO $ CF.writeModule interfFilePath generated 
    return [(fp, mdl)]

-- The following functions partially reimplement
-- https://git.ps.informatik.uni-kiel.de/curry/curry-frontend/-/blob/master/src/Modules.hs
-- since the original module loader/parser does not support virtualized file systems.
-- License     :  BSD-3-clause
-- Copyright   :  (c) 1999 - 2004 Wolfgang Lux
--                    2005        Martin Engelke
--                    2007        Sebastian Fischer
--                    2011 - 2015 Björn Peemöller
--                    2016        Jan Tikovsky
--                    2016 - 2017 Finn Teegen
--                    2018        Kai-Oliver Prott

-- | Loads a single module and performs checks.
loadAndCheckCurryModule :: CO.Options -> FileLoader -> CI.ModuleIdent -> FilePath -> CM (CE.CompEnv ModuleAST)
loadAndCheckCurryModule opts fl m fp = do
    -- Read source file (possibly from VFS)
    src <- liftIO $ fl fp
    -- Load and check module
    loaded <- liftCYIO $ loadCurryModule opts m src fp
    checked <- catchCYIO $ CMD.checkModule opts loaded
    liftCYIO $ warnMessages $ maybe [] (uncurry (CC.warnCheck opts)) checked
    let ast = maybe (Nothing <$ snd loaded) ((Just <$>) . snd) checked
        env = maybe (fst loaded) fst checked
    return (env, ast)

-- | Loads a single module.
loadCurryModule :: CO.Options -> CI.ModuleIdent -> String -> FilePath -> CYIO (CE.CompEnv (CS.Module()))
loadCurryModule opts m src fp = do
    -- Parse the module
    (lexed, ast) <- parseCurryModule opts m src fp
    -- Load the imported interfaces into an InterfaceEnv
    let paths = CFN.addOutDir (CO.optUseOutDir opts) (CO.optOutDir opts) <$> ("." : CO.optImportPaths opts)
    let withPrelude = importCurryPrelude opts ast
    iEnv <- CIF.loadInterfaces paths withPrelude
    checkInterfaces opts iEnv
    is <- importSyntaxCheck iEnv withPrelude
    -- Add Information of imported modules
    cEnv <- CIM.importModules withPrelude iEnv is
    return (cEnv { CE.filePath = fp, CE.tokens = lexed }, ast)

-- | Checks all interfaces.
checkInterfaces :: Monad m => CO.Options -> CEI.InterfaceEnv -> CYT m ()
checkInterfaces opts iEnv = mapM_ checkInterface $ M.elems iEnv
    where checkInterface intf = do
            let env = CIM.importInterfaces intf iEnv
            CC.interfaceCheck opts (env, intf)

-- | Checks all imports in the module.
importSyntaxCheck :: Monad m => CEI.InterfaceEnv -> CS.Module a -> CYT m [CS.ImportDecl]
importSyntaxCheck iEnv (CS.Module _ _ _ _ _ is _) = mapM checkImportDecl is
    where checkImportDecl (CS.ImportDecl p m q asM is') = case M.lookup m iEnv of
            Just intf -> CS.ImportDecl p m q asM `fmap` CC.importCheck intf is'
            Nothing   -> CBM.internalError $ "compiler: No interface for " ++ show m

-- | Ensures that a Prelude is present in the module.
importCurryPrelude :: CO.Options -> CS.Module () -> CS.Module ()
importCurryPrelude opts m@(CS.Module spi li ps mid es is ds) | needed    = CS.Module spi li ps mid es (preludeImpl : is) ds
                                                             | otherwise = m
    where isPrelude = mid == CI.preludeMIdent
          disabled = CS.NoImplicitPrelude `elem` CO.optExtensions opts || m `CS.hasLanguageExtension` CS.NoImplicitPrelude
          imported = CI.preludeMIdent `elem` ((\(CS.ImportDecl _ i _ _ _) -> i) <$> is)
          needed = not isPrelude && not disabled && not imported
          preludeImpl = CS.ImportDecl CSPI.NoSpanInfo CI.preludeMIdent False Nothing Nothing

-- | Parses a single module.
parseCurryModule :: CO.Options -> CI.ModuleIdent -> String -> FilePath -> CYIO ([(CSP.Span, CS.Token)], CS.Module ())
parseCurryModule opts _ src fp = do
    ul <- liftCYM $ CUL.unlit fp src
    -- TODO: Preprocess
    cc <- CNC.condCompile (CO.optCppOpts opts) fp ul
    lexed <- liftCYM $ silent $ CS.lexSource fp cc
    ast <- liftCYM $ CS.parseModule fp cc
    -- TODO: Check module/file mismatch?
    return (lexed, ast)

failedCompilation :: String -> (CompileOutput, CompileState)
failedCompilation msg = (mempty, mempty { csErrors = [failMessageFrom msg] })

failMessageFrom :: String -> CM.Message
failMessageFrom = CM.message . PP.text
