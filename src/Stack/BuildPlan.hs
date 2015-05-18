{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls     #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}


-- | Resolving a build plan for a set of packages in a given Stackage
-- snapshot.

module Stack.BuildPlan
    ( BuildPlanException (..)
    , Snapshots (..)
    , getSnapshots
    , allPackages
    , loadBuildPlan
    , resolveBuildPlan
    , checkBuildPlan
    , findBuildPlan
    , checkDeps
    ) where

import           Control.Applicative             ((<$>), (<*>))
import           Control.Monad                   (when)
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.State.Strict      (State, execState, get, modify,
                                                  put)
import           Control.Monad.Trans.Resource    (runResourceT)
import           Data.Aeson                      (FromJSON (..))
import           Data.Aeson                      (withObject, withText, (.:))
import           Data.Aeson.Parser               (json')
import           Data.Aeson.Types                (parseEither)
import           Data.Conduit                    (($$))
import           Data.Conduit.Attoparsec         (sinkParser)
import qualified Data.Conduit.Binary             as CB
import qualified Data.Foldable                   as F
import qualified Data.HashMap.Strict             as HM
import           Data.IntMap                     (IntMap)
import qualified Data.IntMap                     as IntMap
import           Data.Map                        (Map)
import qualified Data.Map                        as Map
import           Data.Maybe                      (mapMaybe)
import           Data.Monoid                     ((<>))
import           Data.Set                        (Set)
import qualified Data.Set                        as Set
import           Data.Text                       (Text)
import qualified Data.Text                       as T
import           Data.Time                       (Day)
import           Data.Typeable                   (Typeable)
import           Data.Yaml                       (decodeFileEither)
import           Distribution.PackageDescription (GenericPackageDescription,
                                                  flagDefault, flagManual,
                                                  flagName, genPackageFlags)
import           Network.HTTP.Client             (Manager, parseUrl,
                                                  responseBody, withResponse)
import           Network.HTTP.Client.Conduit     (bodyReaderSource)
import           Path
import           Stack.BuildPlan.Types
import           Stack.Constants
import           Stack.FlagName
import           Stack.Package
import           Stack.PackageName
import           Stack.Version
import           System.Directory                (createDirectoryIfMissing,
                                                  getAppUserDataDirectory)
import           System.FilePath                 (takeDirectory)
import qualified System.FilePath                 as FP

data BuildPlanException
    = GetSnapshotsException String
    | UnknownPackages (Set PackageName)
    deriving (Show, Typeable)
instance Exception BuildPlanException

-- | Determine the necessary packages to install to have the given set of
-- packages available.
--
-- This function will not provide test suite and benchmark dependencies.
--
-- This may fail if a target package is not present in the @BuildPlan@.
resolveBuildPlan :: MonadThrow m
                 => BuildPlan
                 -> Set PackageName
                 -> m (Map PackageName (Version, Map FlagName Bool))
resolveBuildPlan bp packages
    | Set.null (rsUnknown rs) = return (rsToInstall rs)
    | otherwise = throwM $ UnknownPackages $ rsUnknown rs
  where
    rs = execState (F.mapM_ (getDeps bp) packages) ResolveState
        { rsVisited = Set.empty
        , rsUnknown = Set.empty
        , rsToInstall = Map.empty
        }

data ResolveState = ResolveState
    { rsVisited   :: Set PackageName
    , rsUnknown   :: Set PackageName
    , rsToInstall :: Map PackageName (Version, Map FlagName Bool)
    }

getDeps :: BuildPlan -> PackageName -> State ResolveState ()
getDeps bp =
    goName
  where
    goName :: PackageName -> State ResolveState ()
    goName name = do
        rs <- get
        when (name `Set.notMember` rsVisited rs) $ do
            put rs { rsVisited = Set.insert name $ rsVisited rs }
            case Map.lookup name $ bpPackages bp of
                Just pkg -> goPkg name pkg
                Nothing ->
                    case Map.lookup name $ siCorePackages $ bpSystemInfo bp of
                        Just _version -> return ()
                        Nothing -> modify $ \rs' -> rs'
                            { rsUnknown = Set.insert name $ rsUnknown rs'
                            }

    goPkg name pp = do
        F.forM_ (Map.toList $ sdPackages $ ppDesc pp) $ \(name', depInfo) ->
            when (includeDep depInfo) (goName name')
        modify $ \rs -> rs
            { rsToInstall = Map.insert name (ppVersion pp, pcFlagOverrides $ ppConstraints pp)
                          $ rsToInstall rs
            }

    includeDep di = CompLibrary `Set.member` diComponents di
                 || CompExecutable `Set.member` diComponents di

-- | Download the 'Snapshots' value from stackage.org.
getSnapshots :: MonadIO m => Manager -> m Snapshots
getSnapshots man = liftIO $ do
    req <- parseUrl $ T.unpack latestSnapshotUrl -- FIXME get from Config
    withResponse req man $ \res -> do
        val <- bodyReaderSource (responseBody res) $$ sinkParser json'
        case parseEither parseJSON val of
            Left e -> throwM $ GetSnapshotsException e
            Right x -> return x

-- | Most recent Nightly and newest LTS version per major release.
data Snapshots = Snapshots
    { snapshotsNightly :: !Day
    , snapshotsLts     :: !(IntMap Int)
    }
    deriving Show
instance FromJSON Snapshots where
    parseJSON = withObject "Snapshots" $ \o -> Snapshots
        <$> (o .: "nightly" >>= parseNightly)
        <*> (fmap IntMap.unions
                $ mapM parseLTS
                $ map snd
                $ filter (isLTS . fst)
                $ HM.toList o)
      where
        parseNightly t =
            case parseSnapName t of
                Left e -> fail $ show e
                Right (LTS _ _) -> fail "Unexpected LTS value"
                Right (Nightly d) -> return d

        isLTS = ("lts-" `T.isPrefixOf`)

        parseLTS = withText "LTS" $ \t ->
            case parseSnapName t of
                Left e -> fail $ show e
                Right (LTS x y) -> return $ IntMap.singleton x y
                Right (Nightly _) -> fail "Unexpected nightly value"

-- | Load the 'BuildPlan' for the given snapshot. Will load from a local copy
-- if available, otherwise downloading from Github.
loadBuildPlan :: (MonadIO m, MonadThrow m, MonadLogger m)
              => Manager
              -> SnapName
              -> m BuildPlan
loadBuildPlan man name = do
    stackage <- liftIO $ getAppUserDataDirectory "stackage"
    let fp = stackage FP.</> "build-plan" FP.</> T.unpack file
    $logDebug $ "Decoding build plan from: " <> T.pack fp
    eres <- liftIO $ decodeFileEither fp
    case eres of
        Right bp -> return bp
        Left e -> do
            $logDebug $ "Decoding failed: " <> T.pack (show e)
            liftIO $ createDirectoryIfMissing True $ takeDirectory fp
            req <- parseUrl $ T.unpack url
            $logDebug $ "Downloading build plan from: " <> url
            liftIO $ withResponse req man $ \res ->
                   runResourceT
                 $ bodyReaderSource (responseBody res)
                $$ CB.sinkFile fp
            liftIO (decodeFileEither fp) >>= either throwM return
  where
    file = renderSnapName name <> ".yaml"
    reponame =
        case name of
            LTS _ _ -> "lts-haskell"
            Nightly _ -> "stackage-nightly"
    url = rawGithubUrl "fpco" reponame "master" file

-- | Get all packages present in the given build plan, including both core and
-- non-core.
allPackages :: BuildPlan -> Map PackageName Version
allPackages bp =
    siCorePackages (bpSystemInfo bp) <>
    fmap ppVersion (bpPackages bp)

-- | Find the set of @FlagName@s necessary to get the given
-- @GenericPackageDescription@ to compile against the given @BuildPlan@. Will
-- only modify non-manual flags, and will prefer default values for flags.
-- Returns @Nothing@ if no combination exists.
checkBuildPlan :: (MonadLogger m, MonadThrow m, MonadIO m)
               => SnapName -- ^ used only for debugging purposes
               -> BuildPlan
               -> Path Abs File -- ^ cabal file path, used only for debugging purposes
               -> GenericPackageDescription
               -> m (Maybe [FlagName])
checkBuildPlan name bp cabalfp gpd = do
    $logDebug $ "Checking against build plan " <> renderSnapName name
    loop flagOptions
  where
    loop [] = return Nothing
    loop (flags:rest) = do
        pkg <- resolvePackage pkgConfig cabalfp gpd
        passes <- checkDeps flags (packageDeps pkg) packages
        if passes
            then return $ Just $ map fst $ filter snd $ Map.toList flags
            else loop rest
      where
        pkgConfig = PackageConfig
            { packageConfigEnableTests = True
            , packageConfigEnableBenchmarks = True
            , packageConfigFlags = flags
            , packageConfigGhcVersion = ghcVersion
            }

    ghcVersion = siGhcVersion $ bpSystemInfo bp

    flagName' = fromCabalFlagName . flagName

    flagOptions = map Map.fromList $ mapM getOptions $ genPackageFlags gpd
    getOptions f
        | flagManual f = [(flagName' f, flagDefault f)]
        | flagDefault f =
            [ (flagName' f, True)
            , (flagName' f, False)
            ]
        | otherwise =
            [ (flagName' f, False)
            , (flagName' f, True)
            ]
    packages = allPackages bp

-- | Checks if the given package dependencies can be satisfied by the given set
-- of packages. Will fail if a package is either missing or has a version
-- outside of the version range.
checkDeps :: MonadLogger m
          => Map FlagName Bool -- ^ used only for debugging purposes
          -> Map PackageName VersionRange
          -> Map PackageName Version
          -> m Bool
checkDeps flags deps packages = do
    let errs = mapMaybe go $ Map.toList deps
    if null errs
        then return True
        else do
            $logDebug $ "Checked against following flags: " <> T.pack (show flags)
            mapM_ $logDebug errs
            return False
  where
    go :: (PackageName, VersionRange) -> Maybe Text
    go (name, range) =
        case Map.lookup name packages of
            Nothing -> Just $ "Package not present: " <> packageNameText name
            Just v
                | withinRange v range -> Nothing
                | otherwise -> Just $ T.concat
                    [ packageNameText name
                    , " version available: "
                    , versionText v
                    , " does not match "
                    , versionRangeText range
                    ]

-- | Find a snapshot and set of flags that is compatible with the given
-- 'GenericPackageDescription'. Returns 'Nothing' if no such snapshot is found.
findBuildPlan :: (MonadIO m, MonadThrow m, MonadLogger m)
              => Manager
              -> Path Abs File
              -> GenericPackageDescription
              -> m (Maybe (SnapName, [FlagName]))
findBuildPlan manager cabalfp gpd = do
    snapshots <- liftIO $ getSnapshots manager
    let names =
            map (uncurry LTS)
                (take 2 $ reverse $ IntMap.toList $ snapshotsLts snapshots)
            ++ [Nightly $ snapshotsNightly snapshots]
        loop [] = return Nothing
        loop (name:names') = do
            bp <- loadBuildPlan manager name
            mflags <- checkBuildPlan name bp cabalfp gpd
            case mflags of
                Nothing -> loop names'
                Just flags -> return $ Just (name, flags)
    loop names