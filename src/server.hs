{-# LANGUAGE Arrows #-}
{-# LANGUAGE TemplateHaskell #-}

{-
  emitter server example
-}

module Main where

import           Control.Applicative ((<$>), (<*>))
import           Control.Concurrent.Async (async, link)
import           Control.Lens hiding ((|>), each)
import qualified Control.Monad.Trans.State.Strict as S
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import           Data.Monoid ((<>))
import           Data.Random.Normal (mkNormals)
import qualified Network.WebSockets as WS
import           Pipes
import           Pipes.Concurrent
import qualified Pipes.Prelude as P
import qualified Pipes.Safe as PS

import           Edge (runEdge)
import           Emitter hiding (main, Plugs(..), wiring, inputTerminal, inputStream, outputEvent)
import           Event as E

-- server technology
inPort :: Int
inPort = 3566

outPort :: Int
outPort = 3567

addr :: String
addr = "0.0.0.0"

wsEvent :: WS.WebSockets WS.Hybi00 (Either ByteString EventIn)
wsEvent = do
    command <- WS.receiveData
    liftIO $ putStrLn $ "received an event: " ++ C.unpack command
    WS.sendTextData $ C.pack $ "server received event: " ++ C.unpack command
    return $ unpack command

websocket :: IO (Input (Either ByteString EventIn))
websocket = do
    (om, im) <- spawn Unbounded
    a <- async $ WS.runServer addr inPort $ \rq -> do
        WS.acceptRequest rq
        liftIO $ putStrLn "accepted incoming request"
        WS.sendTextData $ C.pack "server accepted incoming connection"
        runEffect $ lift wsEvent >~ toOutput om
    link a
    return im

responses :: IO (Output EventOut)
responses = do
    (os, is) <- spawn Unbounded
    let m :: WS.Request -> WS.WebSockets WS.Hybi10 ()
        m rq = do
            WS.acceptRequest rq
            liftIO $ putStrLn "accepted stream request"
            runEffect $ for (fromInput is) (lift . WS.sendTextData . C.pack)
    a <- async $ WS.runServer addr outPort m
    link a
    return $ Output $ \e ->
        case e of
            StreamOut str -> send os $ show str
            _          -> return True

-- | A handle to the process
data WebPlugs = WebPlugs
    { _inputTerminal  :: Input EventIn
    , _inputStream    :: Input EventIn
    , _outputEvent     :: Output EventOut
    , _inputWebSocket  :: Input EventIn
    , _outputWebSocket :: Output EventOut
    }

makeLenses ''WebPlugs

wiring :: Input Double -> IO WebPlugs
wiring rawStream = do
    -- Initialize controllers and views
    -- only terminal in this example
    inTerminal  <- makeInputRight stdinEvent
    outTerminal <- stdoutView
    inRawWS        <- websocket
    inWS <- wireRight inRawWS
    outWS       <- responses

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
    return $ WebPlugs inTerminal inStream oEventOut inWS outWS

main :: IO ()
main = do
    stream <- fromList (mkNormals seed)
    plugs <- wiring stream

    -- recording event streams
    let saveIn = P.tee $ toFile "saves/inServerEmitter.txt"
    let saveOut = P.tee $ toFile "saves/outServerEmitter.txt"

    -- Go!
    PS.runSafeT $ (`S.evalStateT` initialStatus) $ runEffect $
            fromInput (view inputTerminal plugs <>
                       view inputStream plugs <>
                       view inputWebSocket plugs)
        >-> hoist lift saveIn
        >-> runEdge eventHandler
        >-> hoist lift saveOut
        >-> toOutput (view outputEvent plugs <> view outputWebSocket plugs)
