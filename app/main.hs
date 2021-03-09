import Prelude

import Control.Applicative ((<|>), many)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (execStateT, put)
import Data.Foldable (for_, traverse_)
import Data.Text (Text, pack, unpack)
import Data.Traversable (for)
import System.Exit (ExitCode(ExitFailure, ExitSuccess), exitWith)
import System.FilePath.Posix ((</>))
import qualified Data.Set as Set
import qualified Options.Applicative as Opt

import Data.Prune.Cabal (parseCabalFiles, parseCabalProjectFile)
import Data.Prune.Dependency (getDependencyByModule)
import Data.Prune.ImportParser (getCompilableUsedDependencies)
import Data.Prune.Stack (parseStackYaml)
import qualified Data.Prune.Types as T

data Opts = Opts
  { optsProjectRoot :: FilePath
  , optsPackages :: [Text]
  }

parseArgs :: IO Opts
parseArgs = Opt.execParser (Opt.info (Opt.helper <*> parser) $ Opt.progDesc "Prune a Stack project's dependencies")
  where
    parser = Opts
      <$> Opt.strOption (
        Opt.long "project-root"
          <> Opt.metavar "PROJECT_ROOT"
          <> Opt.help "Project root"
          <> Opt.value "."
          <> Opt.showDefault )
      <*> many ( pack <$> Opt.strOption (
        Opt.long "package"
          <> Opt.metavar "PACKAGE"
          <> Opt.help "Package name(s)" ) )

main :: IO ()
main = do
  Opts {..} <- parseArgs

  packageDirs <- parseStackYaml (optsProjectRoot </> "stack.yaml")
    <|> parseCabalProjectFile (optsProjectRoot </> "cabal.project")
  packages <- parseCabalFiles packageDirs optsPackages

  dependencyByModule <- liftIO $ getDependencyByModule packages
  code <- flip execStateT ExitSuccess $ for_ packages $ \T.Package {..} -> do
    baseUsedDependencies <- fmap mconcat . for packageCompilables $ \compilable@T.Compilable {..} -> do
      usedDependencies <- liftIO $ getCompilableUsedDependencies dependencyByModule compilable
      let (baseUsedDependencies, otherUsedDependencies) = Set.partition (flip Set.member packageBaseDependencies) usedDependencies
          otherUnusedDependencies = Set.difference compilableDependencies otherUsedDependencies
      unless (Set.null otherUnusedDependencies) $ do
        liftIO . putStrLn . unpack $ "Some unused dependencies for " <> pack (show compilableType) <> " " <> T.unCompilableName compilableName <> " in package " <> packageName
        traverse_ (liftIO . putStrLn . unpack . ("  " <>) . T.unDependencyName) $ Set.toList otherUnusedDependencies
        put $ ExitFailure 1
      pure baseUsedDependencies
    let baseUnusedDependencies = Set.difference packageBaseDependencies baseUsedDependencies
    unless (Set.null baseUnusedDependencies) $ do
      liftIO . putStrLn . unpack $ "Some unused base dependencies for package " <> packageName
      liftIO . traverse_ (putStrLn . unpack . ("  " <>) . T.unDependencyName) $ Set.toList baseUnusedDependencies
      put $ ExitFailure 1
  exitWith code
