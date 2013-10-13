{-# LANGUAGE Arrows #-}
{-# LANGUAGE TemplateHaskell #-}

{-
  emitter event example

-}

module Emitter where

import           Control.Applicative ((<$>), (<*>))
import           Control.Arrow ((>>>), arr)
import qualified Control.Foldl as F
import           Control.Lens hiding ((|>), each)
import           Control.Monad (unless)
import qualified Control.Monad.Trans.State.Strict as S
import qualified Data.ByteString.Char8 as C
import           Data.Monoid ((<>))
import           Data.Random.Normal (mkNormals)
import           Pipes
import           Pipes.Concurrent
import           Pipes.Core (push)
import qualified Pipes.Prelude as P
import qualified Pipes.Safe as PS

import           Ema
import           Event as E
import           Edge (Edge(Edge), runEdge)

-- constants
seed :: Int
seed = 42

-- data types
data Param
    = Delay   {-# UNPACK #-} !Double
    | MaxStream {-# UNPACK #-} !Int
    | Total   {-# UNPACK #-} !Double
    | Drift   {-# UNPACK #-} !Double
    | Sigma   {-# UNPACK #-} !Double
    | Dt      {-# UNPACK #-} !Double
    | Ema1    {-# UNPACK #-} !Double
    | Ema2    {-# UNPACK #-} !Double
    deriving (Show, Eq, Read)

data Status = Status
    { _streamDelay   :: {-# UNPACK #-} !Double -- delaying the stream
    , _streamPause   ::                !Bool   -- pausing the stream
    , _streamMax     :: {-# UNPACK #-} !Int    -- maximum stream count
    , _streamTotal   :: {-# UNPACK #-} !Double -- running calc
    , _pDrift   :: {-# UNPACK #-} !Double -- drift parameter
    , _pSigma   :: {-# UNPACK #-} !Double -- volatility parameter
    , _pDt      :: {-# UNPACK #-} !Double -- time grain
    , _pEma1    :: {-# UNPACK #-} !Double -- ema calc 1 (0=latest, 1=average)
    , _pEma2    :: {-# UNPACK #-} !Double -- ema calc 2
    } deriving (Show)

makeLenses ''Status

initialStatus :: Status
initialStatus = Status 1.0 True 200 0 0 1 1 0.5 0.1

data Command
    = Stop
    | Go
    | ResetDelay Double
    | ResetMaxStream Int
    | ResetTotal Double
    | Help deriving (Show, Eq, Read)

data EventIn
    = StartUp
    | ShutDown
    | StreamIn Double
    | Command Command
    | Param Param
    deriving (Show, Eq, Read)

data EventOut
    = SetPause Bool
    | SetDelay Double
    | StreamOut (Double, Double)
    deriving (Show, Eq, Read)

packIn :: EventIn -> String
packIn ShutDown = "quit"
packIn StartUp = "start"
packIn (Command x) = case x of
    Go   -> "go"
    Stop -> "stop"
    Help -> "help"
    ResetDelay xs -> unwords ["rdelay", show xs]
    ResetMaxStream xs -> unwords ["rmaxstream", show xs]
    ResetTotal xs -> unwords ["rtotal", show xs]
packIn (Param x)  = case x of
    Delay xs   -> unwords ["delay"   ,show xs]
    MaxStream xs -> unwords ["maxstream" ,show xs]
    Total  xs  -> unwords ["total"   ,show xs]
    Drift  xs  -> unwords ["drift"   ,show xs]
    Sigma  xs  -> unwords ["sigma"   ,show xs]
    Dt     xs  -> unwords ["dt"      ,show xs]
    Ema1   xs  -> unwords ["ema1"    ,show xs]
    Ema2   xs  -> unwords ["ema2"    ,show xs]
packIn (StreamIn x) = unwords ["streamin",show x]

unpackIn :: String -> EventIn
unpackIn x      = case words x of
    ["go"]          -> Command Go
    ["stop"]        -> Command Stop
    ["quit"]        -> ShutDown
    ["start"]       -> StartUp
    ["help"]        -> Command Help
    ["rdelay", xs]  -> Command $ ResetDelay $ read xs
    ["rmaxstream", xs] -> Command $ ResetMaxStream $ read xs
    ["rtotal", xs]  -> Command $ ResetTotal $ read xs
    ["streamin", xs] -> StreamIn  $ read xs
    ["delay"  , xs] -> Param $ Delay   $ read xs
    ["maxstream", xs] -> Param $ MaxStream $ read xs
    ["total"  , xs] -> Param $ Total   $ read xs
    ["drift"  , xs] -> Param $ Drift   $ read xs
    ["sigma"  , xs] -> Param $ Sigma   $ read xs
    ["dt"     , xs] -> Param $ Dt      $ read xs
    ["ema1"   , xs] -> Param $ Ema1    $ read xs
    ["ema2"   , xs] -> Param $ Ema2    $ read xs
    _               -> Command Help


instance Event EventIn where
    pack = C.pack . packIn
    unpack = Right . unpackIn . C.unpack

instance Event EventOut


-- Controllers and Views
help :: String
help = unwords
    [ "go"
    , "stop"
    , "quit"
    , "help"
    , "rdelay"
    , "rmaxstream"
    , "rtotal"
    , "delay"
    , "maxstream"
    , "total"
    , "drift"
    , "sigma"
    , "dt"
    , "ema1"
    , "ema2"
    , "data"
    ]


-- All the pure logic.  Note that none of these use 'IO'
updateStatus :: (Monad m) => Param -> S.StateT Status m ()
updateStatus p =
    case p of
        Delay   p' -> streamDelay .= p'
        MaxStream p' -> streamMax .= p'
        Total   p' -> streamTotal .= p'
        Drift   p' -> pDrift .= p'
        Sigma   p' -> pSigma .= p'
        Dt      p' -> pDt .= p'
        Ema1    p' -> pEma1 .= p'
        Ema2    p' -> pEma2 .= p'

takeMax :: (Monad m) => Edge (S.StateT Status m) () a a
takeMax = Edge (takeLoop 0)
  where
    takeLoop count a = do
        m <- use streamMax
        unless (count >= m) $ do
            yield a
            a2 <- await
            takeLoop (count + 1) a2

-- turns a random stream into a random walk stream
walker :: (Monad m) => Edge (S.StateT Status m) () Double Double
walker = Edge $ push ~> \a -> do
    t <- use streamTotal
    dr <- use pDrift
    dt <- use pDt
    sigma <- use pSigma
    let t' = t + dr * dt + sigma * sqrt dt * a
    streamTotal .= t'
    yield t'

emaStats :: (Monad m) => Edge (S.StateT Status m) r Double (Double, Double)
emaStats = Edge $ \a -> do
    p1 <- use pEma1
    p2 <- use pEma2
    case (,) <$> ema p1 <*> ema p2 of
        F.Fold step begin done -> push a >-> P.scan step begin done

streamer :: (Monad m) => Edge (S.StateT Status m) () Double EventOut
streamer =
        walker
    >>> takeMax
    >>> emaStats
    >>> arr StreamOut

commandHandler :: (Monad m) => Edge (S.StateT Status m) () Command EventOut
commandHandler = Edge $ push ~> \e -> case e of
    Stop -> do
        streamPause .= True
        yield $ SetPause True
    Go   -> do
        streamPause .= False
        yield $ SetPause False
    ResetDelay d -> do
        streamDelay .= d
        yield $ SetDelay d
    ResetTotal t -> streamTotal .= t
    ResetMaxStream m  -> streamMax .= m
    _ -> return ()

paramHandler :: (Monad m) => Edge (S.StateT Status m) () Param x
paramHandler = Edge $ push ~> (lift . updateStatus)

eventHandler :: (Monad m) => Edge (S.StateT Status m) () EventIn EventOut
eventHandler = proc e ->
    case e of
        StreamIn x  -> streamer       -< x
        Command b   -> commandHandler -< b
        Param   p   -> paramHandler   -< p
        ShutDown    -> Edge return           -< ()
        StartUp     -> Edge $ push ~> return -< ()

-- | A handle to the process
data Plugs = Plugs
    { _inputTerminal  :: Input EventIn
    , _inputStream    :: Input EventIn
    , _outputEvent     :: Output EventOut
    }

makeLenses ''Plugs

wiring :: Input Double -> IO Plugs
wiring rawStream = do
    -- Initialize controllers and views
    -- only terminal in this example
    inTerminal  <- makeInputRight stdinEvent
    outTerminal <- stdoutView

    -- interface for effectful StreamIn controllers
    (inDelay, outSetDelay) <- E.delay $ view streamDelay initialStatus
    (inPause, outSetPause) <- E.pause $ view streamPause initialStatus

    -- add time delay and pause
    let inStream = (\_ _ a -> StreamIn a) <$> inPause <*> inDelay <*> rawStream

    -- output direction
    let oEventOut = Output $ \e -> case e of
            StreamOut x -> send outTerminal x
            SetDelay  x -> send outSetDelay x
            SetPause  x -> send outSetPause x
    return $ Plugs inTerminal inStream oEventOut

main :: IO ()
main = do
    stream <- fromList (mkNormals seed)
    plugs <- wiring stream

    -- recording event streams
    let saveIn = P.tee $ toFile "saves/inEmitter.txt"
    let saveOut = P.tee $ toFile "saves/outEmitter.txt"

    -- Go!
    PS.runSafeT $ (`S.evalStateT` initialStatus) $ runEffect $
            fromInput (view inputTerminal plugs <> view inputStream plugs)
        >-> hoist lift saveIn
        >-> runEdge eventHandler
        >-> hoist lift saveOut
        >-> toOutput (view outputEvent plugs)

