{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}

module Main where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map as Map
import qualified Data.Aeson as A
import qualified Data.Yaml as Y

import Control.Monad.Catch (throwM, Exception, MonadThrow)
import Control.Monad (mapM_)
import Control.Arrow (second, left)

import System.Environment (lookupEnv, getEnv)
import System.Directory (getHomeDirectory)
import System.FilePath.Posix ((</>))

import Kubernetes.Client.Config (KubeConfigSource(..), mkKubeClientConfig, mkInClusterClientConfig, setTokenAuth)
import Kubernetes.Client.Auth.OIDC (OIDCCache)
import Kubernetes.OpenAPI.API.CoreV1 (readNamespacedConfigMap)
import Kubernetes.OpenAPI.MimeTypes (Accept(..), MimeJSON(..))
import Kubernetes.OpenAPI.Model (Name(..), Namespace(..), V1ConfigMap(..))
import Kubernetes.OpenAPI.Client (MimeResult(..), MimeError, dispatchMime)
import Kubernetes.OpenAPI.Core

import Network.HTTP.Client (Manager)

import GHC.Conc (newTVarIO)

data K8SFailure = K8SMimeFailure String MimeError
  deriving Show
instance Exception K8SFailure

data Dependency = Dependency
  { githubRepo :: String
  , githubRef  :: String
  } deriving Show

newtype Dependencies = Dependencies { unDependencies :: [Dependency] }

instance A.FromJSON Dependency where
  parseJSON = A.withObject "Dependency" $ \o -> do
    githubRepo <- o A..: "github"
    githubRef  <- o A..: "ref"
    return Dependency{..}

instance A.FromJSON Dependencies where
  parseJSON = A.withObject "Depenencies" $ fmap Dependencies . (A..: "apps")


main :: IO ()
main = do
  (manager, cfg) <- getK8SConfiguration
  configMapRequest <- getConfigMapRequest
  configMap <- assertMimeResult =<< dispatchMime manager cfg configMapRequest

  either error (mapM_ print . unDependencies) $
    extractDependencies configMap

  where
    getConfigMapRequest =
      readNamespacedConfigMap (Accept MimeJSON) configMapName <$> getNamespaceFromEnv


getK8SConfiguration :: IO (Manager, KubernetesClientConfig)
getK8SConfiguration = getK8sSource >>= \case
  KubeConfigCluster -> mkInClusterClientConfig
  localConfig -> do
    token <- getToken
    cache <- makeEmptyCache
    second (setTokenAuth token) <$> mkKubeClientConfig cache localConfig

assertMimeResult :: MonadThrow m => MimeResult res -> m res
assertMimeResult (MimeResult (Left err) _) = throwM $ K8SMimeFailure "Mime Error" err
assertMimeResult (MimeResult (Right res) _) = return res

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
configMapName = Name "juvo-dependencies"

extractDependencies :: V1ConfigMap -> Either String Dependencies
extractDependencies cfgmap = do
  yaml <- maybe (Left "Dependencies not found") Right $
    v1ConfigMapData cfgmap >>= Map.lookup "dependencies.yaml"
  left show . Y.decodeEither' . T.encodeUtf8 $ yaml

