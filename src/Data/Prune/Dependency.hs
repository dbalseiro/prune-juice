module Data.Prune.Dependency where

import Prelude hiding (words)

import Data.Foldable (find)
import Data.Map (Map)
import Data.Maybe (mapMaybe)
import Data.Text (Text, isPrefixOf, pack, strip, unpack, words)
import Data.Traversable (for)
import System.Exit (ExitCode(ExitFailure, ExitSuccess))
import Turtle (shellStrict)
import qualified Data.Map as Map
import qualified Data.Set as Set

import Data.Prune.ImportParser (parseExposedModules)
import qualified Data.Prune.Types as T

runOrFail :: Text -> IO Text
runOrFail cmd = shellStrict cmd mempty >>= \case
  (ExitSuccess, out) -> pure out
  (ExitFailure _, out) -> fail . unpack $ "Failed to \"" <> cmd <> "\" due to " <> out

getPackageDependencyByModule :: FilePath -> T.Package -> IO (Map T.ModuleName T.DependencyName)
getPackageDependencyByModule stackYamlFile T.Package {..} = do
  let allDependencies = packageBaseDependencies <> foldMap T.compilableDependencies packageCompilables
      tupleDependency x = (, x) <$> find (\d -> isPrefixOf (T.unDependencyName d) x) allDependencies
  compilerBin <- strip <$> runOrFail ("stack --stack-yaml " <> pack stackYamlFile <> " path --compiler-bin")
  snapshotPkgDb <- strip <$> runOrFail ("stack --stack-yaml " <> pack stackYamlFile <> " path --snapshot-pkg-db")
  globalPkgDb <- strip <$> runOrFail ("stack --stack-yaml " <> pack stackYamlFile <> " path --global-pkg-db")
  let snapshotGhcPkg = compilerBin <> "/ghc-pkg --package-db " <> snapshotPkgDb
      globalGhcPkg = compilerBin <> "/ghc-pkg --package-db " <> globalPkgDb
  snapshotPkgs <- mapMaybe tupleDependency . words . strip
    <$> runOrFail (snapshotGhcPkg <> " list --simple-output")
  globalPkgs <- mapMaybe tupleDependency . words . strip
    <$> runOrFail (globalGhcPkg <> " list --simple-output")
  snapshotDependencyByModule <- fmap mconcat . for snapshotPkgs $ \(dependencyName, pkg) -> do
    moduleNames <- parseExposedModules . unpack . strip =<< runOrFail (snapshotGhcPkg <> " field " <> pkg <> " exposed-modules")
    pure . Map.fromList . map (, dependencyName) . Set.toList $ moduleNames
  globalDependencyByModule <- fmap mconcat . for globalPkgs $ \(dependencyName, pkg) -> do
    moduleNames <- parseExposedModules . unpack . strip =<< runOrFail (globalGhcPkg <> " field " <> pkg <> " exposed-modules")
    pure . Map.fromList . map (, dependencyName) . Set.toList $ moduleNames
  pure $ snapshotDependencyByModule <> globalDependencyByModule