{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeFamilies      #-}

module Ide.Plugin.Example2
  (
    descriptor
  ) where

import Control.DeepSeq ( NFData )
import Control.Monad.Trans.Maybe
import Data.Aeson
import Data.Binary
import Data.Functor
import qualified Data.HashMap.Strict as Map
import qualified Data.HashSet as HashSet
import Data.Hashable
import qualified Data.Text as T
import Data.Typeable
import Development.IDE.Core.OfInterest
import Development.IDE.Core.RuleTypes
import Development.IDE.Core.Rules
import Development.IDE.Core.Service
import Development.IDE.Core.Shake
import Development.IDE.Types.Diagnostics as D
import Development.IDE.Types.Location
import Development.IDE.Types.Logger
import Development.Shake hiding ( Diagnostic )
import GHC.Generics
import Ide.Plugin
import Ide.Types
import Language.Haskell.LSP.Types
import Text.Regex.TDFA.Text()

-- ---------------------------------------------------------------------

descriptor :: PluginId -> PluginDescriptor
descriptor plId = PluginDescriptor
  { pluginId = plId
  , pluginRules = exampleRules
  , pluginCommands = [PluginCommand "codelens.todo" "example adding" addTodoCmd]
  , pluginCodeActionProvider = Just codeAction
  , pluginCodeLensProvider   = Just codeLens
  , pluginDiagnosticProvider = Nothing
  , pluginHoverProvider      = Just hover
  , pluginSymbolsProvider    = Just symbols
  , pluginFormattingProvider = Nothing
  , pluginCompletionProvider = Just completion
  }

-- ---------------------------------------------------------------------

hover :: IdeState -> TextDocumentPositionParams -> IO (Either ResponseError (Maybe Hover))
hover = request "Hover" blah (Right Nothing) foundHover

blah :: NormalizedFilePath -> Position -> Action (Maybe (Maybe Range, [T.Text]))
blah _ (Position line col)
  = return $ Just (Just (Range (Position line col) (Position (line+1) 0)), ["example hover 2\n"])

-- ---------------------------------------------------------------------
-- Generating Diagnostics via rules
-- ---------------------------------------------------------------------

data Example2 = Example2
    deriving (Eq, Show, Typeable, Generic)
instance Hashable Example2
instance NFData   Example2
instance Binary   Example2

type instance RuleResult Example2 = ()

exampleRules :: Rules ()
exampleRules = do
  define $ \Example2 file -> do
    _pm <- getParsedModule file
    return ([], Just ())

  action $ do
    files <- getFilesOfInterest
    void $ uses Example2 $ HashSet.toList files


-- ---------------------------------------------------------------------
-- code actions
-- ---------------------------------------------------------------------

-- | Generate code actions.
codeAction
    :: IdeState
    -> PluginId
    -> TextDocumentIdentifier
    -> Range
    -> CodeActionContext
    -> IO (Either ResponseError (List CAResult))
codeAction _state _pid (TextDocumentIdentifier uri) _range CodeActionContext{_diagnostics=List _xs} = do
    let
      title = "Add TODO2 Item"
      tedit = [TextEdit (Range (Position 3 0) (Position 3 0))
               "-- TODO2 added by Example2 Plugin directly\n"]
      edit  = WorkspaceEdit (Just $ Map.singleton uri $ List tedit) Nothing
    pure $ Right $ List
        [ CACodeAction $ CodeAction title (Just CodeActionQuickFix) (Just $ List []) (Just edit) Nothing ]

-- ---------------------------------------------------------------------

codeLens
    :: IdeState
    -> PluginId
    -> CodeLensParams
    -> IO (Either ResponseError (List CodeLens))
codeLens ideState plId CodeLensParams{_textDocument=TextDocumentIdentifier uri} = do
    logInfo (ideLogger ideState) "Example2.codeLens entered (ideLogger)" -- AZ
    case uriToFilePath' uri of
      Just (toNormalizedFilePath -> filePath) -> do
        _ <- runAction ideState $ runMaybeT $ useE TypeCheck filePath
        _diag <- getDiagnostics ideState
        _hDiag <- getHiddenDiagnostics ideState
        let
          title = "Add TODO2 Item via Code Lens"
          range = Range (Position 3 0) (Position 4 0)
        let cmdParams = AddTodoParams uri "do abc"
        cmd <- mkLspCommand plId "codelens.todo" title (Just [toJSON cmdParams])
        pure $ Right $ List [ CodeLens range (Just cmd) Nothing ]
      Nothing -> pure $ Right $ List []

-- ---------------------------------------------------------------------
-- | Parameters for the addTodo PluginCommand.
data AddTodoParams = AddTodoParams
  { file   :: Uri  -- ^ Uri of the file to add the pragma to
  , todoText :: T.Text
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

addTodoCmd :: AddTodoParams -> IO (Either ResponseError Value,
                           Maybe (ServerMethod, ApplyWorkspaceEditParams))
addTodoCmd (AddTodoParams uri todoText) = do
  let
    pos = Position 5 0
    textEdits = List
      [TextEdit (Range pos pos)
                  ("-- TODO2:" <> todoText <> "\n")
      ]
    res = WorkspaceEdit
      (Just $ Map.singleton uri textEdits)
      Nothing
  return (Right Null, Just (WorkspaceApplyEdit, ApplyWorkspaceEditParams res))

-- ---------------------------------------------------------------------

foundHover :: (Maybe Range, [T.Text]) -> Either ResponseError (Maybe Hover)
foundHover (mbRange, contents) =
  Right $ Just $ Hover (HoverContents $ MarkupContent MkMarkdown
                        $ T.intercalate sectionSeparator contents) mbRange


-- | Respond to and log a hover or go-to-definition request
request
  :: T.Text
  -> (NormalizedFilePath -> Position -> Action (Maybe a))
  -> Either ResponseError b
  -> (a -> Either ResponseError b)
  -> IdeState
  -> TextDocumentPositionParams
  -> IO (Either ResponseError b)
request label getResults notFound found ide (TextDocumentPositionParams (TextDocumentIdentifier uri) pos _) = do
    mbResult <- case uriToFilePath' uri of
        Just path -> logAndRunRequest label getResults ide pos path
        Nothing   -> pure Nothing
    pure $ maybe notFound found mbResult

logAndRunRequest :: T.Text -> (NormalizedFilePath -> Position -> Action b)
                  -> IdeState -> Position -> String -> IO b
logAndRunRequest label getResults ide pos path = do
  let filePath = toNormalizedFilePath path
  logInfo (ideLogger ide) $
    label <> " request at position " <> T.pack (showPosition pos) <>
    " in file: " <> T.pack path
  runAction ide $ getResults filePath pos

-- ---------------------------------------------------------------------

symbols :: SymbolsProvider
symbols _ide (DocumentSymbolParams _doc _mt)
    = pure $ Right [r]
    where
        r = DocumentSymbol name detail kind deprecation range selR chList
        name = "Example2_symbol_name"
        detail = Nothing
        kind = SkVariable
        deprecation = Nothing
        range = Range (Position 4 1) (Position 4 7)
        selR = range
        chList = Nothing

-- ---------------------------------------------------------------------

completion :: CompletionProvider
completion _ide (CompletionParams _doc _pos _mctxt _mt)
    = pure $ Right $ Completions $ List [r]
    where
        r = CompletionItem label kind detail documentation deprecated preselect
                           sortText filterText insertText insertTextFormat
                           textEdit additionalTextEdits commitCharacters
                           command xd
        label = "Example2 completion"
        kind = Nothing
        detail = Nothing
        documentation = Nothing
        deprecated = Nothing
        preselect = Nothing
        sortText = Nothing
        filterText = Nothing
        insertText = Nothing
        insertTextFormat = Nothing
        textEdit = Nothing
        additionalTextEdits = Nothing
        commitCharacters = Nothing
        command = Nothing
        xd = Nothing

-- ---------------------------------------------------------------------
