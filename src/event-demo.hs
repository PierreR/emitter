{-# LANGUAGE Arrows #-}
{-# LANGUAGE TemplateHaskell #-}

{-

An event processor showing:

- typical wiring using Inputs and Outputs from Pipes.Concurrent
- use of Event class
- use of a timed event (TEvent)
- saving and replaying events (with and without time effects)
- pure process logic testing

-}

module Main where

import           Control.Applicative ((<$>), (<*>))
import           Control.Arrow ((>>>), arr)
import           Control.Lens hiding ((|>), each)
import           Control.Monad (unless)
import           Control.Monad.Identity (runIdentity)
import qualified Control.Monad.Trans.State.Strict as S
import           Data.ByteString (ByteString)
import           Data.Monoid ((<>))
import           Pipes ((~>), (>->), await, yield, runEffect, hoist, lift, each)
import           Pipes.Concurrent (fromInput, toOutput, send, Output(..), Input(..))
import           Pipes.Core (push)
import qualified Pipes.Prelude    as P
import qualified Pipes.Safe       as PS
import           Prelude hiding (writeFile, readFile)

import           Edge (Edge(Edge), runEdge)
import           Event as E

-- Status
data Status = Status
    { _streamDelay :: Double  -- delay the stream by x seconds
    , _streamMax   :: Integer -- maximum stream count
    , _streamTotal :: Double  -- running total of stream
    , _streamPause :: Bool    -- is stream paused
    } deriving (Show, Eq)

makeLenses ''Status

initialStatus :: Status
initialStatus = Status 1.0 20 0 False

-- event datatypes
data EventIn
    = NoEvent
    | StartUp
    | ShutDown
    | Stop
    | Go
    | StreamIn Double
    | ResetDelay Double
    | ResetTotal Double
    | ResetMaxStream Integer
    deriving (Show, Eq, Read)

instance Event EventIn

data EventOut
    = NoEventOut
    | SetPause Bool
    | SetDelay Double
    | Message ByteString
    | StreamOut Double
    deriving (Show, Eq, Read)

instance Event EventOut

-- Edges
-- stream pipes
-- check maximum stream count
checkMaxStream :: (Monad m) => Edge (S.StateT Status m) () a a
checkMaxStream = Edge (loop 0)
  where
    loop count a = do
        m <- use streamMax
        unless (count >= m) $ do
            yield a
            a2 <- await
            loop (count + 1) a2

-- accumulate the stream values
accumulateStream :: (Monad m) => Edge (S.StateT Status m) () Double Double
accumulateStream = Edge $ push ~> \a -> do
    streamTotal += a
    t <- use streamTotal
    yield t

-- EventIn handlers
streamHandler :: (Monad m) => Edge (S.StateT Status m) () Double EventOut
streamHandler =
        checkMaxStream
    >>> accumulateStream
    >>> arr StreamOut

commandHandler :: (Monad m) => Edge (S.StateT Status m) () EventIn EventOut
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

eventHandler :: (Monad m) => Edge (S.StateT Status m) () EventIn EventOut
eventHandler = proc e -> case e of
    StreamIn x  -> streamHandler         -< x
    NoEvent     -> Edge $ push ~> return -< ()
    ShutDown    -> Edge return           -< ()
    StartUp     -> Edge $ push ~> return -< ()
    _           -> commandHandler        -< e


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
main = demo

demo :: IO ()
demo = do
    stream <- fromList ([1..]::[Double])
    plugs <- wiring stream

    -- recording event streams
    let saveIn = P.tee $ toFile "saves/in.txt"
    let saveOut = P.tee $ toFile "saves/out.txt"
    -- let saveOut' = toFile "saves/out.txt"
    -- Go!
    PS.runSafeT $ (`S.evalStateT` initialStatus) $ runEffect $
            fromInput (view inputTerminal plugs <> view inputStream plugs)
        >-> hoist lift saveIn
        >-> runEdge eventHandler
        >-> hoist lift saveOut
        >-> toOutput (view outputEvent plugs)

demoTimed :: IO ()
demoTimed = do

    stream <- fromList ([1..]::[Double])
    plugs <- wiring stream

    -- recording event streams
    let saveIn = P.tee $ toFileAddTime "saves/inTimed.txt"
    let saveOut = P.tee $ toFileAddTime "saves/outTimed.txt"

    -- Go!
    PS.runSafeT $ (`S.evalStateT` initialStatus) $ runEffect $
            fromInput (view inputTerminal plugs <>
                       view inputStream plugs)
        >-> hoist lift saveIn
        >-> runEdge eventHandler
        >-> hoist lift saveOut
        >-> toOutput (view outputEvent plugs)

-- a (timeless) replay of an event file
replayTimeless :: IO ()
replayTimeless = do
    -- Initialize controllers and views
    outTerminal <- stdoutView

    -- output directing
    let oEventOut = Output $ \e -> case e of
            StreamOut str  -> send outTerminal str
            SetDelay _  -> return True
            SetPause _  -> return True

    -- loading an event stream
    let loadIn = fromFileRight "saves/in.txt"
        saveReplayOut = P.tee $ toFile "saves/outReplayTimeless.txt"

    -- Go!
    PS.runSafeT $ (`S.evalStateT` initialStatus) $ runEffect $
            hoist lift loadIn
        >-> runEdge eventHandler
        >-> hoist lift saveReplayOut
        >-> toOutput oEventOut

-- a (timefull) replay of an event file
replayTimed :: IO ()
replayTimed = do
    -- Initialize controllers and views
    outTerminal <- stdoutView

    -- output directing
    let oEventOut = Output $ \e -> case e of
            StreamOut str  -> send outTerminal str
            SetDelay _  -> return True
            SetPause _  -> return True

    -- loading an event stream
    loadIn <- timedEvent $ fromFileRight "saves/inTimed.txt"
    let saveReplayOut = P.tee $ toFileAddTime "saves/outReplayTimed.txt"

    -- Go!
    PS.runSafeT $ (`S.evalStateT` initialStatus) $ runEffect $
            fromInput loadIn
        >-> runEdge eventHandler
        >-> hoist lift saveReplayOut
        >-> toOutput oEventOut

-- eventHandler in the Identity monad
replayPure :: [EventIn] -> [EventOut]
replayPure eventin =
    runIdentity $ (`S.evalStateT` initialStatus) $
    P.toListM (each eventin >-> runEdge eventHandler)

test1 :: Bool
test1 = replayPure dataInput1 == cannedOutput1

dataInput1 :: [EventIn]
dataInput1 =
    [ StreamIn 1.0
    , StreamIn 2.0
    , StreamIn 3.0
    , StreamIn 4.0
    , StreamIn 5.0
    , Stop
    , StreamIn 6.0
    , StreamIn 7.0
    , ResetTotal 0.0
    , ResetMaxStream 10
    , Go
    , StreamIn 8.0
    , StreamIn 9.0
    , StreamIn 10.0
    , StreamIn 11.0
    ]

cannedOutput1 :: [EventOut]
cannedOutput1 =
    [
      StreamOut 1.0
    , StreamOut 3.0
    , StreamOut 6.0
    , StreamOut 10.0
    , StreamOut 15.0
    , SetPause True
    , StreamOut 21.0
    , StreamOut 28.0
    , SetPause False
    , StreamOut 8.0
    , StreamOut 17.0
    , StreamOut 27.0
    ]
