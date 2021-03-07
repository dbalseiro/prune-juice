module Data.Prune.Internal where

import Prelude

import Data.Map (Map)
import Data.Set (Set)
import Data.Text (pack)
import Data.Traversable (for)
import Hpack.Config
  ( Section, decodeOptionsTarget, decodeResultPackage, defaultDecodeOptions, packageBenchmarks
  , packageConfig, packageExecutables, packageInternalLibraries, packageLibrary, packageName
  , packageTests, readPackageConfig, sectionDependencies, sectionSourceDirs, unDependencies
  )
import System.Directory (doesDirectoryExist, listDirectory, pathIsSymbolicLink)
import System.FilePath.Posix ((</>), isExtensionOf)
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Yaml as Yaml

import qualified Data.Prune.Types as T

listFilesRecursive :: FilePath -> IO (Set FilePath)
listFilesRecursive dir = do
  dirs <- listDirectory dir
  fmap mconcat . for dirs $ \case
    -- don't include "hidden" directories, i.e. those that start with a '.'
    '.' : _ -> pure mempty
    fn -> do
      let
        path = if dir == "." then fn else dir </> fn
      isDir <- doesDirectoryExist path
      isSymlink <- pathIsSymbolicLink path
      case (isSymlink, isDir) of
        (True, _) -> pure mempty
        (_, True) -> listFilesRecursive path
        _ -> pure $ Set.singleton path

getSectionDependencyNames :: Section a -> Set T.DependencyName
getSectionDependencyNames = Set.fromList . map (T.DependencyName . pack) . Map.keys . unDependencies . sectionDependencies

-- FIXME get main file for an executable
getSectionFiles :: FilePath -> Section a -> IO (Set FilePath)
getSectionFiles fp section = fmap mconcat . for (sectionSourceDirs section) $ \dir -> do
  allFiles <- listFilesRecursive $ fp </> dir
  pure $ Set.filter (isExtensionOf "hs") allFiles

getSectionCompilables :: FilePath -> T.CompilableType -> Map String (Section a) -> IO [T.Compilable]
getSectionCompilables fp typ sections = for (Map.toList sections) $ \(name, section) -> do
  sourceFiles <- getSectionFiles fp section
  pure $ T.Compilable (T.CompilableName (pack name)) typ (getSectionDependencyNames section) sourceFiles

parsePackageYaml :: FilePath -> IO T.Package
parsePackageYaml fp = do
  package <- either fail (pure . decodeResultPackage) =<< readPackageConfig (defaultDecodeOptions { decodeOptionsTarget = fp </> packageConfig })
  let baseDependencies = maybe mempty getSectionDependencyNames $ packageLibrary package
  libraries   <- getSectionCompilables fp T.CompilableTypeLibrary    $ packageInternalLibraries package
  executables <- getSectionCompilables fp T.CompilableTypeExecutable $ packageExecutables package
  tests       <- getSectionCompilables fp T.CompilableTypeTest       $ packageTests package
  benchmarks  <- getSectionCompilables fp T.CompilableTypeBenchmark  $ packageBenchmarks package
  pure T.Package
    { packageName = pack $ packageName package
    , packageBaseDependencies = baseDependencies
    , packageCompilables = libraries <> executables <> tests <> benchmarks
    }

parseStackYaml :: FilePath -> IO [T.Package]
parseStackYaml fp = do
  T.StackYaml {..} <- either (fail . ("Couldn't parse stack.yaml due to " <>) . show) pure . Yaml.decodeEither' =<< BS.readFile (fp </> "stack.yaml")
  traverse parsePackageYaml stackYamlPackages
