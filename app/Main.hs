{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}

{-# OPTIONS -Wall #-}

module Main (main) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map as Map
import qualified Data.Aeson as A
import qualified Data.Yaml as Y
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString as BS

import Control.Arrow (second, left)
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (MVar, takeMVar, newEmptyMVar, putMVar)

import System.Environment (lookupEnv, getEnv)
import System.Directory (getHomeDirectory)
import System.FilePath.Posix ((</>))

import Kubernetes.Client.Config (KubeConfigSource(..), mkKubeClientConfig, mkInClusterClientConfig, setTokenAuth)
import Kubernetes.Client.Watch (dispatchWatch, eventObject, eventType, WatchEvent)
import Kubernetes.Client.Auth.OIDC (OIDCCache)
import Kubernetes.OpenAPI.API.CoreV1 (readNamespacedConfigMap, listNamespacedConfigMap)
import Kubernetes.OpenAPI.MimeTypes (Accept(..), MimeJSON(..))
import Kubernetes.OpenAPI.Model (Name(..), Namespace(..), V1ConfigMap(..), V1ObjectMeta(..))
import Kubernetes.OpenAPI.Client (MimeResult(..), MimeError(..), dispatchMime)
import Kubernetes.OpenAPI.Core

import qualified Streaming as S
import qualified Streaming.Prelude as SP
import qualified Streaming.ByteString as SB
import qualified Streaming.ByteString.Char8 as SB8

import Network.HTTP.Client (Manager)

import GHC.Conc (newTVarIO)

data Dependency = Dependency
  { githubRepo :: String
  , githubRef  :: String
  } deriving Show

newtype Dependencies = Dependencies [Dependency]

instance A.FromJSON Dependency where
  parseJSON = A.withObject "Dependency" $ \o -> do
    githubRepo <- o A..: "github"
    githubRef  <- o A..: "ref"
    return Dependency{..}

instance A.FromJSON Dependencies where
  parseJSON = A.withObject "Dependencies" $ fmap Dependencies . (A..: "apps")


main :: IO ()
main = do
  (manager, cfg) <- getK8SConfiguration
  namespace <- getNamespaceFromEnv

  dispatchMime manager cfg (configMapRequest namespace) >>= \case
    MimeResult (Left (MimeError err _)) _ -> do
      putStrLn "ConfigMap not found"
      putStrLn err
    MimeResult (Right configMap) _ ->
      either decodingError printDependencies $
        extractDependencies configMap

  putStrLn "Start WATCHING"
  isDeleted <- newEmptyMVar
  race (takeMVar isDeleted)
       (dispatchWatch manager cfg (watchConfigMapRequest namespace) (handleStream isDeleted))
        >>= either handleStop handleError

  where
    watchConfigMapRequest = listNamespacedConfigMap (Accept MimeJSON)
    configMapRequest = readNamespacedConfigMap (Accept MimeJSON) configMapName

    decodingError err = do
      putStrLn "Error getting depedencies list :("
      putStrLn err

    printDependencies (Dependencies deps) = do
      putStrLn "Read dependencies from K8s: "
      mapM_ print deps

    handleStop () = putStrLn "Stopped watching. It has been deleted??"
    handleError () = putStrLn "An error occured, boo-hoo"

    handleStream result stream =
      let segmented :: S.Stream (SB.ByteStream IO) IO ()
          segmented = SB8.lines stream

          processed :: S.Stream (S.Of LBS.ByteString) IO ()
          processed = S.mapped SB.toLazy segmented

          individualized :: S.Stream (S.Of (WatchEvent V1ConfigMap)) IO ()
          individualized = SP.mapMaybe A.decode' processed

          filtered :: S.Stream (S.Of (WatchEvent V1ConfigMap)) IO ()
          filtered = SP.filter isJuvoDependencies individualized

          actioned :: S.Stream (S.Of BS.ByteString) IO ()
          actioned = SP.mapM (depsChangedAction result) filtered

          rechunked :: S.Stream (SB.ByteStream IO) IO ()
          rechunked = SP.with actioned SB.chunk

      in SB.stdout $ SB8.unlines rechunked

getK8SConfiguration :: IO (Manager, KubernetesClientConfig)
getK8SConfiguration = getK8sSource >>= \case
  KubeConfigCluster -> mkInClusterClientConfig
  localConfig -> do
    token <- getToken
    cache <- makeEmptyCache
    second (setTokenAuth token) <$> mkKubeClientConfig cache localConfig

makeEmptyCache :: IO OIDCCache
makeEmptyCache = newTVarIO (Map.fromList mempty)

getK8sSource :: IO KubeConfigSource
getK8sSource = do
  isLocal <- (== Just "true") <$> lookupEnv "K8S_LOCAL"
  if isLocal
     then KubeConfigFile <$> getKubeConfigFile
     else return KubeConfigCluster

getKubeConfigFile :: IO FilePath
getKubeConfigFile = do
  home <- getHomeDirectory
  return (home </> ".kube" </> "config")

getNamespaceFromEnv :: IO Namespace
getNamespaceFromEnv = Namespace . T.pack . fromMaybe "default" <$> lookupEnv "K8S_NAMESPACE"

getToken :: IO Text
getToken = T.pack <$> getEnv "K8S_TOKEN"

configMapName :: Name
configMapName = Name configMapText

configMapText :: Text
configMapText = "juvo-dependencies"

isJuvoDependencies :: WatchEvent V1ConfigMap -> Bool
isJuvoDependencies cm = (v1ConfigMapMetadata (eventObject cm) >>= v1ObjectMetaName) == Just configMapText

extractDependencies :: V1ConfigMap -> Either String Dependencies
extractDependencies cfgmap = do
  yaml <- maybe (Left "Dependencies not found") Right $
    v1ConfigMapData cfgmap >>= Map.lookup "dependencies.yaml"
  left show . Y.decodeEither' . T.encodeUtf8 $ yaml

depsChangedAction :: MVar () -> WatchEvent V1ConfigMap -> IO BS.ByteString
depsChangedAction result watch =
  case eventType watch of
    "ADDED" -> do
      printDeps
      return "Config Map added... I just printed it"

    "MODIFIED" -> do
      printDeps
      return "Config Map modified... I just printed it"

    "DELETED" -> do
      putMVar result ()
      return "DELETED RESOURCE => STOP WATCHING"

    tp -> return . T.encodeUtf8 $ "unrecognized type " <> tp

  where
    printDeps :: IO ()
    printDeps =
      case extractDependencies (eventObject watch) of
        Left err -> putStrLn err
        Right (Dependencies deps) -> mapM_ print deps

