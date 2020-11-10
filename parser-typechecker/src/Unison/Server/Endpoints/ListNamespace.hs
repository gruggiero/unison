{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Unison.Server.Endpoints.ListNamespace where

import Control.Error (runExceptT)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Aeson (ToJSON)
import Data.OpenApi (ToSchema)
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant (Get, JSON, QueryParam, ServerError (errBody), err400, throwError, (:>))
import Servant.Docs (DocQueryParam (..), ParamKind (Normal), ToParam (..), ToSample (..))
import Servant.OpenApi ()
import Servant.Server (Handler)
import Unison.Codebase (Codebase)
import qualified Unison.Codebase as Codebase
import qualified Unison.Codebase.Branch as Branch
import qualified Unison.Codebase.Causal as Causal
import qualified Unison.Codebase.Path as Path
import Unison.ConstructorType (ConstructorType)
import qualified Unison.Hash as Hash
import qualified Unison.HashQualified as HQ
import qualified Unison.HashQualified' as HQ'
import qualified Unison.Name as Name
import qualified Unison.NameSegment as NameSegment
import Unison.Parser (Ann)
import Unison.Pattern (SeqOp)
import qualified Unison.PrettyPrintEnv as PPE
import qualified Unison.Reference as Reference
import qualified Unison.Referent as Referent
import qualified Unison.Server.Backend as Backend
import Unison.Server.Errors (backendError, badHQN, badNamespace, rootBranchError)
import Unison.Server.Types
  ( HashQualifiedName,
    Size,
    UnisonHash,
    UnisonName,
    mayDefault,
  )
import Unison.ShortHash (ShortHash)
import Unison.Type (Type)
import qualified Unison.TypePrinter as TypePrinter
import Unison.Util.Pretty (Width, render)
import Unison.Util.SyntaxText (SyntaxText')
import qualified Unison.Util.SyntaxText as SyntaxText
import Unison.Var (Var)

type NamespaceAPI =
  "list" :> QueryParam "namespace" HashQualifiedName
    :> Get '[JSON] NamespaceListing

instance ToParam (QueryParam "namespace" Text) where
  toParam _ =
    DocQueryParam
      "namespace"
      [".", ".base.List", "foo.bar"]
      "The fully qualified name of a namespace. The leading `.` is optional."
      Normal

instance ToSample NamespaceListing where
  toSamples _ =
    [ ( "When no value is provided for `namespace`, the root namespace `.` is "
        <> "listed by default"
      , NamespaceListing
        "."
        "gjlk0dna8dongct6lsd19d1o9hi5n642t8jttga5e81e91fviqjdffem0tlddj7ahodjo5"
        [Subnamespace $ NamedNamespace "base" 1244]
      )
    ]

data NamespaceListing = NamespaceListing
  { namespaceListingName :: UnisonName,
    namespaceListingHash :: UnisonHash,
    namespaceListingChildren :: [NamespaceObject]
  }
  deriving (Generic, Show)

instance ToJSON NamespaceListing

deriving instance ToSchema NamespaceListing

data NamespaceObject
  = Subnamespace NamedNamespace
  | TermObject NamedTerm
  | TypeObject NamedType
  | PatchObject NamedPatch
  deriving (Generic, Show)

instance ToJSON NamespaceObject

deriving instance ToSchema NamespaceObject

data NamedNamespace = NamedNamespace
  { namespaceName :: UnisonName,
    namespaceSize :: Size
  }
  deriving (Generic, Show)

instance ToJSON NamedNamespace

deriving instance ToSchema NamedNamespace

data NamedTerm = NamedTerm
  { termName :: HashQualifiedName,
    termHash :: UnisonHash,
    termType :: Maybe (SyntaxText' ShortHash)
  }
  deriving (Generic, Show)

instance ToJSON NamedTerm

deriving instance ToSchema NamedTerm

data NamedType = NamedType
  { typeName :: HashQualifiedName,
    typeHash :: UnisonHash
  }
  deriving (Generic, Show)

instance ToJSON NamedType

deriving instance ToSchema NamedType

data NamedPatch = NamedPatch
  { patchName :: HashQualifiedName
  }
  deriving (Generic, Show)

instance ToJSON NamedPatch

deriving instance ToSchema NamedPatch

newtype KindExpression = KindExpression {kindExpressionText :: Text}
  deriving (Generic, Show)

instance ToJSON KindExpression

deriving instance ToSchema KindExpression

formatType ::
  Var v => PPE.PrettyPrintEnv -> Width -> Type v a -> SyntaxText' ShortHash
formatType ppe w =
  fmap (fmap Reference.toShortHash) . render w
    . TypePrinter.pretty0
      ppe
      mempty
      (-1)

instance ToJSON ConstructorType

deriving instance ToSchema ConstructorType

instance ToJSON SeqOp

deriving instance ToSchema SeqOp

instance ToJSON r => ToJSON (Referent.TermRef r)

deriving instance ToSchema r => ToSchema (Referent.TermRef r)

instance ToJSON r => ToJSON (SyntaxText.Element r)

deriving instance ToSchema r => ToSchema (SyntaxText.Element r)

instance ToJSON r => ToJSON (SyntaxText' r)

deriving instance ToSchema r => ToSchema (SyntaxText' r)

backendListEntryToNamespaceObject ::
  Var v =>
  PPE.PrettyPrintEnv ->
  Maybe Width ->
  Backend.ShallowListEntry v a ->
  NamespaceObject
backendListEntryToNamespaceObject ppe typeWidth = \case
  Backend.ShallowTermEntry r name mayType ->
    TermObject $
      NamedTerm
        { termName = HQ'.toText name,
          termHash = Referent.toText r,
          termType = formatType ppe (mayDefault typeWidth) <$> mayType
        }
  Backend.ShallowTypeEntry r name ->
    TypeObject $
      NamedType
        { typeName = HQ'.toText name,
          typeHash = Reference.toText r
        }
  Backend.ShallowBranchEntry name size ->
    Subnamespace $
      NamedNamespace
        { namespaceName = NameSegment.toText name,
          namespaceSize = size
        }
  Backend.ShallowPatchEntry name ->
    PatchObject . NamedPatch $ NameSegment.toText name

serveNamespace ::
  Var v =>
  Codebase IO v Ann ->
  Maybe HashQualifiedName ->
  Handler NamespaceListing
serveNamespace codebase mayHQN = case mayHQN of
  Nothing -> serveNamespace codebase $ Just "."
  Just hqn -> do
    parsedName <- parseHQN hqn
    case parsedName of
      HQ.NameOnly n -> do
        path' <- parsePath $ Name.toString n
        gotRoot <- liftIO $ Codebase.getRootBranch codebase
        root <- errFromEither rootBranchError gotRoot
        hashLength <- liftIO $ Codebase.hashLength codebase
        let p = either id (Path.Absolute . Path.unrelative) $ Path.unPath' path'
            ppe =
              Backend.basicSuffixifiedNames hashLength root $ Path.fromPath' path'
        entries <- findShallow p
        pure
          . NamespaceListing
            (Name.toText n)
            (Hash.base32Hex . Causal.unRawHash $ Branch.headHash root)
          $ fmap (backendListEntryToNamespaceObject ppe Nothing) entries
      HQ.HashOnly _ -> hashOnlyNotSupported
      HQ.HashQualified _ _ -> hashQualifiedNotSupported
  where
    errFromMaybe e = maybe (throwError e) pure
    errFromEither f = either (throwError . f) pure
    parseHQN hqn = errFromMaybe (badHQN hqn) $ HQ.fromText hqn
    parsePath p = errFromEither (flip badNamespace p) $ Path.parsePath' p
    findShallow p = do
      ea <- liftIO . runExceptT $ Backend.findShallow codebase p
      errFromEither backendError ea
    hashOnlyNotSupported =
      throwError $
        err400
          { errBody = "This server does not yet support searching namespaces by hash."
          }
    hashQualifiedNotSupported =
      throwError $
        err400
          { errBody =
              "This server does not yet support searching namespaces by "
                <> "hash-qualified name."
          }