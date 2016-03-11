{-# LANGUAGE ConstraintKinds, ImplicitParams, LambdaCase, TemplateHaskell #-}

module Main where

import           Cases (snakify)
import           Control.Concurrent
import qualified Control.Exception as C
import           Control.Lens
import           Control.Monad.State
import           Data.Aeson.TH
import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HM
import           Data.List (isPrefixOf, sort)
import qualified Data.Map as M
import           Data.Maybe
import           Data.Time
import qualified Data.Yaml as Y
import qualified Data.Yaml.Pretty as Y
import qualified Data.Text as T
import qualified Data.Text.Lens as T (packed)
import           System.Directory
import           System.Exit
import           System.FilePath ((</>))
import           System.FilePath.Lens
import           System.IO
import           System.IO.Temp
import           System.IO.Unsafe
import           System.Process

import           Formura.NumericalConfig

----------------------------------------------------------------
-- External Functions Utilities
----------------------------------------------------------------

cmd :: String -> IO ExitCode
cmd str = do
  hPutStrLn stderr str
  system str

-- copy remote file/local file/url from one another
superCopy :: FilePath -> FilePath -> IO ()
superCopy src dest = do
  let isUrl = or [x `isPrefixOf` src | x <- ["http://", "https://", "ftp://"]]
      go :: (String -> IO ()) -> IO ()
      go k
        | isUrl = withSystemTempFile "tmp" $ \fn h -> do
            hClose h
            cmd $ "wget " ++ src ++ " -O " ++ fn
            k fn
        | otherwise = k src
  go $ \fn -> do
    cmd $ unwords ["scp -r ", fn, dest]
    return ()

writeYaml :: Y.ToJSON a => FilePath -> a -> IO ()
writeYaml fn obj = BS.writeFile fn $ Y.encodePretty (Y.setConfCompare compare Y.defConfig) obj

readYaml :: Y.FromJSON a => FilePath -> IO (Maybe a)
readYaml fn = do
  Y.decodeFileEither fn >>= \case
    Left msg -> do
      hPutStrLn stderr $ "When reading " ++ fn ++ "\n" ++ Y.prettyPrintParseException msg
      return Nothing
    Right x -> return $ Just x

readYamlDef :: (Y.ToJSON a, Y.FromJSON a) => a -> FilePath -> IO (Maybe a)
readYamlDef def fn = do
  Y.decodeFileEither fn >>= \case
    Left msg -> do
      hPutStrLn stderr $ "When reading " ++ fn ++ "\n" ++ Y.prettyPrintParseException msg
      return Nothing
    Right v -> do
      let v2 :: Y.Value
          v2 = unionValue v (Y.toJSON def)
      case (Y.decodeEither' $ Y.encode v2) of
        Left msg -> do
          hPutStrLn stderr $ "When merginf " ++ fn ++ "\n" ++ Y.prettyPrintParseException msg
          return Nothing
        Right x -> return $ Just x

  where
    unionValue :: Y.Value -> Y.Value -> Y.Value
    unionValue (Y.Object hm1) (Y.Object hm2) = Y.Object $ HM.unionWith unionValue hm1 hm2
    unionValue a _ = a

-- Object !Object
-- Array !Array
-- String !Text
-- Number !Scientific
-- Bool !Bool
-- Null


readCmd :: String -> IO String
readCmd str = interactCmd str ""

interactCmd
    :: String                   -- ^ shell command to run
    -> String                   -- ^ standard input
    -> IO String                -- ^ stdout + stderr
interactCmd cmdstr input = do
    (Just inh, Just outh, _, pid) <-
        createProcess (shell cmdstr){ std_in  = CreatePipe,
                                      std_out = CreatePipe,
                                      std_err = Inherit }

    -- fork off a thread to start consuming the output
    output  <- hGetContents outh
    outMVar <- newEmptyMVar
    forkIO $ C.evaluate (length output) >> putMVar outMVar ()

    -- now write and flush any input
    when (not (null input)) $ do hPutStr inh input; hFlush inh
    hClose inh -- done with stdin

    -- wait on the output
    takeMVar outMVar
    hClose outh

    -- wait on the process
    ex <- waitForProcess pid

    case ex of
     ExitSuccess   -> return output
     ExitFailure r ->
      error ("readSystem: " ++ cmdstr ++ " (exit " ++ show r ++ ")")



----------------------------------------------------------------
-- Incubator Datatypes
----------------------------------------------------------------


data Action = Codegen
            | Compile
            | Benchmark
            | Visualize
            | Done
            | Failed
              deriving (Eq, Ord, Show, Read)

deriveJSON defaultOptions ''Action

data WaitFile = WaitLocalFile FilePath
              | WaitRemoteFile FilePath
              deriving (Eq, Ord, Show, Read)

data QBConfig =
  QBConfig
  { _qbHostName :: String
  , _qbWorkDir :: String
  , _qbLabNotePath :: String
  , _qbRemoteLabNotePath :: String
  }

makeClassy ''QBConfig

$(deriveJSON (let toSnake = T.packed %~ snakify in
               defaultOptions{fieldLabelModifier = toSnake . drop 3,
                              constructorTagModifier = toSnake,
                              omitNothingFields = True})
  ''QBConfig)


qbConfigFilePath :: FilePath
qbConfigFilePath = ".qb/config"

qbDefaultConfig = QBConfig
  { _qbHostName = "K"
  , _qbWorkDir = ".qb/"
  , _qbLabNotePath = "/home/nushio/hub/3d-mhd/individuals"
  , _qbRemoteLabNotePath = "/volume81/data/ra000008/nushio/individuals"}

type WithQBConfig = ?qbc :: QBConfig

data Individual =
  Individual
  { _idvFormuraVersion :: String
  , _idvFmrSourcecodeURL :: String
  , _idvCppSourcecodeURL :: String
  , _idvNumericalConfig :: NumericalConfig
  , _idvCompilerFlags :: [String]
  } deriving (Eq, Ord, Read, Show)

makeClassy ''Individual

$(deriveJSON (let toSnake = T.packed %~ snakify in
               defaultOptions{fieldLabelModifier = toSnake . drop 4,
                              constructorTagModifier = toSnake,
                              omitNothingFields = True})
  ''Individual)

defaultIndividual :: Individual
defaultIndividual = Individual
  { _idvFormuraVersion = "3aed540676dca114e9367ef1d94b0b3ca00ea8f4"
  , _idvFmrSourcecodeURL = "/home/nushio/hub/formura/examples/3d-mhd.fmr"
  , _idvCppSourcecodeURL = "/home/nushio/hub/formura/examples/3d-mhd-main-prof.cpp"
  , _idvNumericalConfig = unsafePerformIO $ fromJust <$> readYaml "/home/nushio/hub/formura/examples/3d-mhd.yaml"
  , _idvCompilerFlags = []
  }


data Experiment =
  Experiment
  { _xpAction :: Action
  , _xpIndividualFilePath :: FilePath
  , _xpExperimentFilePath :: FilePath
  , _xpLocalWorkDir :: String
  , _xpLocalCodePaths :: [String]
  , _xpRemoteWorkDir :: String
  , _xpRemoteExecPath :: String
  , _xpRemoteOutputPath :: String
  , _xpImagePath :: String
  , _xpTimeStamps :: [(UTCTime,Action)]
  } deriving (Eq, Ord, Read, Show)

makeClassy ''Experiment

$(deriveJSON (let toSnake = T.packed %~ snakify in
               defaultOptions{fieldLabelModifier = toSnake . drop 3,
                              constructorTagModifier = toSnake,
                              omitNothingFields = True})
  ''Experiment)

defaultExperiment :: Experiment
defaultExperiment = Experiment
  { _xpAction = Codegen
  , _xpIndividualFilePath = ""
  , _xpExperimentFilePath = ""
  , _xpLocalWorkDir = ""
  , _xpLocalCodePaths = [""]
  , _xpRemoteWorkDir = ""
  , _xpRemoteExecPath = ""
  , _xpRemoteOutputPath = ""
  , _xpImagePath = ""
  , _xpTimeStamps = []
  }


data IndExp = IndExp Individual Experiment
            deriving (Eq, Ord, Show, Read)

instance HasIndividual IndExp where
  individual f (IndExp i x) = (\i -> IndExp i x) <$> f i
instance HasExperiment IndExp where
  experiment f (IndExp i x) = (\x -> IndExp i x) <$> f x


data IncubatorState =
  IncubatorState
  { _qbConfig :: QBConfig
  , _qbIndividual :: Individual}

makeClassy ''IncubatorState

instance HasQBConfig IncubatorState where
  qBConfig = qbConfig

instance HasIndividual IncubatorState where
  individual = qbIndividual


----------------------------------------------------------------
-- Incubator functions
----------------------------------------------------------------

remoteCmd :: WithQBConfig => String -> IO ExitCode
remoteCmd str = do
  let host = ?qbc ^. qbHostName
  cmd $ "ssh " ++ host ++ " '(" ++ str ++ ")'"


readIndExp :: FilePath -> IO (Maybe IndExp)
readIndExp fn = do
  readYamlDef defaultIndividual fn >>= \case
    Nothing -> return Nothing
    Just idv0 -> do
      let xpfn = fn & extension .~ "exp"
      xp0 <- maybe defaultExperiment id <$> readYamlDef defaultExperiment xpfn
      let xp1 = xp0
            { _xpLocalWorkDir = fn ^. directory
            , _xpIndividualFilePath = fn
            , _xpExperimentFilePath = xpfn
            }
      return $ Just $ IndExp idv0 xp1

writeIndExp :: IndExp -> IO ()
writeIndExp it = do
  writeYaml (it ^. xpIndividualFilePath) (it ^. individual)
  writeYaml (it ^. xpExperimentFilePath) (it ^. experiment)

getCodegen :: WithQBConfig => String -> IO FilePath
getCodegen gitKey = do
  absPath <- getCurrentDirectory
  let fn = cpath </>("formura-" ++ gitKey)
      cpath = absPath </> (?qbc ^. qbWorkDir) </> "compilers"
  cmd $ "mkdir -p " ++ cpath
  doesFileExist fn >>= \case
    True -> return fn
    False -> do
      withSystemTempDirectory "qb-codegen" $ \dir -> do
        withCurrentDirectory dir $ do
          putStrLn dir
          cmd $ "git clone /home/nushio/hub/formura ."
          cmd $ "git checkout " ++ gitKey
          cmd $ "stack install --local-bin-path ./bin"
          cmd $ "cp ./bin/formura " ++ fn
      return fn

codegen :: WithQBConfig => IndExp -> IO IndExp
codegen it = do
  let labNote = ?qbc ^. qbLabNotePath
      codeDir = it ^. xpLocalWorkDir </> "src"
  cmd $ "mkdir -p " ++ codeDir
  codegenFn <- getCodegen $ it ^. idvFormuraVersion
  withCurrentDirectory codeDir $ do
    superCopy (it ^. idvFmrSourcecodeURL) "3d-mhd.fmr"
    superCopy (it ^. idvCppSourcecodeURL) "3d-mhd-main.cpp"
    writeYaml "3d-mhd.yaml" $ it ^. idvNumericalConfig
    cmd $ "rm *.c *.cpp *.h"
    cmd $ codegenFn ++ " main.fmr"
    foundFiles <- fmap (sort . lines) $ readCmd $ "find ."
    let csrcFiles =
          [fn | fn <- foundFiles, fn ^. extension == ".cpp"] ++
          [fn | fn <- foundFiles, fn ^. extension == ".c"]
        objFiles = [fn & extension .~ "o"  |fn <- csrcFiles]

        c2oCmd fn = unlines
          [ (fn & extension .~ "o") ++ ": " ++ fn
          , "\t$(CC) -c $^ -o $@"]

    writeFile "Makefile" $ unlines
      [ "all: a.out"
      , "CC=mpiFCCpx " ++ unwords (it ^. idvCompilerFlags)
      , "OBJS=" ++ unwords objFiles
      , "a.out: $(OBJS)"
      , "\t$(CC) $(OBJS) -o a.out"
      , unlines $ map c2oCmd csrcFiles]


  return $ it
    & xpAction .~ Compile
    & xpLocalCodePaths .~ [codeDir]

compile :: WithQBConfig => IndExp -> IO IndExp
compile it = do
  let localWD = it ^. xpLocalWorkDir
      localLN  = ?qbc ^. qbLabNotePath
      remoteLN = ?qbc ^. qbRemoteLabNotePath
  forM (it ^. xpLocalCodePaths) $ \srcdir -> do
    let remotedir = srcdir & T.packed %~ T.replace (T.pack localLN) (T.pack remoteLN)
    remoteCmd $ "mkdir -p " ++ remotedir
    cmd $ "rsync -avz " ++ (srcdir++"/") ++ " " ++ (?qbc^.qbHostName++":"++remotedir++"/")
    remoteCmd $ "cd " ++ remotedir ++ ";make -j8"
  return it

benchmark :: IndExp -> IO IndExp
benchmark idv = return idv

visualize :: IndExp -> IO IndExp
visualize = return


main :: IO ()
main = do
  x <- doesFileExist qbConfigFilePath
  if not x then mainInit else mainServer

mainInit :: IO ()
mainInit = do
  cmd "mkdir -p .qb"
  writeYaml qbConfigFilePath qbDefaultConfig

mainServer :: IO ()
mainServer = do
  putStrLn "Qppy!"
  Just qbc0 <- readYaml qbConfigFilePath
  let ?qbc = qbc0 :: QBConfig
  let noteDir = ?qbc ^. qbLabNotePath
  findIdvs <- readCmd $ "find " ++ noteDir ++ " -name '*.idv'"
  let idvFns = lines findIdvs

  idxps <- catMaybes <$> mapM readIndExp idvFns

  mapM_ proceed idxps

  return ()

proceed :: WithQBConfig => IndExp -> IO ()
proceed it = do
  print it
  newIt <- case it ^. xpAction of
    Codegen -> codegen it
    Compile -> compile it
    x -> do
      hPutStrLn stderr $ "Unimplemented Action: " ++ show x
      return it

  writeIndExp newIt

{- note: to submit interactive job on greatwave:

 pjsub --interact -L node=4 -L elapse=2:00:00 -L rscunit=gwmpc

-}