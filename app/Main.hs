{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map as Map

import Control.Monad.Catch (throwM, Exception, MonadThrow)
import Control.Arrow (second)

import System.Environment (lookupEnv, getEnv)
import System.Directory (getHomeDirectory)
import System.FilePath.Posix ((</>))

import Kubernetes.Client.Config (KubeConfigSource(..), mkKubeClientConfig, setTokenAuth)
import Kubernetes.Client.Auth.OIDC (OIDCCache)
import Kubernetes.OpenAPI.API.CoreV1 (readNamespacedConfigMap)
import Kubernetes.OpenAPI.MimeTypes (Accept(..), MimeJSON(..))
import Kubernetes.OpenAPI.Model (Name(..), Namespace(..))
import Kubernetes.OpenAPI.Client (MimeResult(..), MimeError, dispatchMime)
import Kubernetes.OpenAPI.Core

import GHC.Conc (newTVarIO)

data K8SFailure = K8SMimeFailure String MimeError
  deriving Show
instance Exception K8SFailure

main :: IO ()
main = do
  cache <- makeEmptyCache
  source <- getK8sSource
  token <- getToken
  (manager, cfg) <- second (setTokenAuth token) <$> mkKubeClientConfig cache source
  configMapRequest <- readNamespacedConfigMap (Accept MimeJSON) <$> configMapName <*> getNamespaceFromEnv
  configMap <- assertMimeResult =<< dispatchMime manager cfg configMapRequest
  print configMap
  return ()

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

configMapName :: IO Name
configMapName = return $ Name "juvo-dependencies"

