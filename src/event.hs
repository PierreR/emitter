{-# LANGUAGE Arrows #-}
{-# LANGUAGE TypeFamilies, RankNTypes, OverloadedStrings #-}


{-
basic mvc/arrow logic applied to events
saving input and output events
canned test
-}

module Event where

import           Prelude hiding (putStrLn, writeFile, readFile)

import           Control.Applicative ((<$>), (<*>))
import           Control.Arrow ((>>>), arr)
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.STM (newTVarIO, readTVar, writeTVar, retry)
import           Control.Monad (unless, liftM, forever)
import           Control.Monad.Identity (runIdentity)
import qualified Control.Monad.Trans.State.Strict as S
import           Data.ByteString (ByteString)
import           Data.ByteString.Char8 (putStrLn)
import qualified Data.ByteString.Char8 as C
import           Data.Monoid ((<>))
import           System.IO (openFile, hClose, IOMode(..))

import           Edge (Edge(Edge), runEdge)
import           Pipes
import qualified Pipes.ByteString as PB
import           Pipes.Concurrent
import           Pipes.Core (push)
import           Pipes.Internal (unsafeHoist)
import qualified Pipes.Parse      as PP
import qualified Pipes.Prelude    as P
import qualified Pipes.Safe       as PS

-- data types
data Param
    = Delay   {-# UNPACK #-} !Double
    | MaxTake {-# UNPACK #-} !Int
    | Start   {-# UNPACK #-} !Double
    deriving (Show)

data Params = Params
    { delay   :: {-# UNPACK #-} !Double
    , maxTake :: {-# UNPACK #-} !Int
    , start   :: {-# UNPACK #-} !Double
    } deriving (Show)

defaultParams :: Params
defaultParams = Params
    { delay   = 1.0  -- delay in seconds
    , maxTake = 1000 -- maximum number of stream elements
    , start   = 0    -- start data
    }

data Command
    = Quit
    | Stop
    | Go
    | Help
    deriving (Show)

data EventIn
    = NoEvent
    | Data Double
    | Command Command
    | Param Param
    deriving (Show)

data EventOut
    = NoEventOut
    | Set Double
    | UnSet
    | Message ByteString
    | Stream ByteString
    deriving (Show)

-- Controllers and Views
help :: ByteString
help = C.unwords
    [ "go"
    , "stop"
    , "quit"
    , "help"
    , "delay"
    , "maxtake"
    , "start"
    , "data"
    ]

stdinEvent :: IO EventIn
stdinEvent = liftM makeEventIn C.getLine

makeInput :: IO a -> IO (Input a)
makeInput p = do
    (o, i) <- spawn Unbounded
    a <- async $ runEffect $ lift p >~ toOutput o
    link a
    return i

terminalView :: IO (Output ByteString)
terminalView = do
    (os, is) <- spawn Unbounded
    a <- async $ runEffect $ fromInput is >-> P.print
    link a
    return os

-- The input generates ticks and the output lets you Set or UnSet ticks
ticks :: IO (Input (), Output EventOut)
ticks = do
    (oTick, iTick) <- spawn Unbounded
    tvar   <- newTVarIO Nothing
    let pause = do
            d <- atomically $ do
                x <- readTVar tvar
                case x of
                    Nothing -> retry
                    Just d  -> return d
            threadDelay $ truncate $ 1000000 * d
    a <- async $ runEffect $ lift pause >~ toOutput oTick
    link a
    let oChange = Output $ \e -> do
            case e of
                Set d -> writeTVar tvar (Just d)
                UnSet -> writeTVar tvar  Nothing
                _    -> return ()
            return True
    return (iTick, oChange)

fromList :: [a] -> IO (Input a)
fromList as = do
    (o, i) <- spawn Single
    a <- async $ runEffect $ each as >-> toOutput o
    link a
    return i

-- file helpers
readFile :: FilePath
	 -> Producer' ByteString (PS.SafeT IO) ()
readFile file = PS.bracket
    (do h <- openFile file ReadMode
	putStrLn $ C.concat ["{",C.pack file," open}"]
	return h )
    (\h -> do
	  hClose h
	  putStrLn $ C.concat ["{",C.pack file," closed}"] )
    PB.fromHandle

writeFile :: FilePath
	 -> Consumer' ByteString (PS.SafeT IO) ()
writeFile file = PS.bracket
    (do h <- openFile file WriteMode
	putStrLn $ C.concat ["{",C.pack file," open}"]
	return h )
    (\h -> do
	  hClose h
	  putStrLn $ C.concat ["{",C.pack file," closed}"])
    PB.toHandle

packEventIn :: (Monad m) => Pipe EventIn ByteString m r
packEventIn = forever $ do
    s <- await
    yield $ C.append (unmakeEventIn s) "\n"

unpackEventIn :: (Monad m) => Pipe ByteString EventIn m r
unpackEventIn = forever $ do
    s <- await
    -- lift $ putStrLn $ C.append "unpacked: " s
    yield $ makeEventIn $ C.takeWhile (/= '\n') s

packEventOut :: (Monad m) => Pipe EventOut ByteString m r
packEventOut = forever $ do
    s <- await
    yield $ C.append (unmakeEventOut s) "\n"

unpackEventOut :: Pipe ByteString EventOut IO r
unpackEventOut = forever $ do
    s <- await
    -- lift $ putStrLn $ C.append "unpacked: " s
    yield $ makeEventOut $ C.takeWhile (/= '\n') s

takeLines :: Monad m => Producer ByteString m () -> Producer ByteString m ()
takeLines = unlines' . PB.lines

unlines' :: (Monad m)
    => PP.FreeT (Producer ByteString m) m r
    -> Producer ByteString m r
unlines' = go
  where
    go f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                f' <- p
                go f'

-- All the pure logic.  Note that none of these use 'IO'
-- EventIn
makeEventIn :: ByteString -> EventIn
makeEventIn x      = case C.words x of
    ["go"]          -> Command Go
    ["stop"]        -> Command Stop
    ["quit"]        -> Command Quit
    ["help"]        -> Command Help
    ["data"   , xs] -> Data  $ read $ C.unpack xs
    ["delay"  , xs] -> Param $ Delay   $ read $ C.unpack xs
    ["maxtake", xs] -> Param $ MaxTake $ read $ C.unpack xs
    ["start"  , xs] -> Param $ Start   $ read $ C.unpack xs
    _               -> Command Help

unmakeEventIn :: EventIn -> ByteString
unmakeEventIn (Command x) = case x of
    Go   -> "go"
    Stop -> "stop"
    Quit -> "quit"
    Help -> "help"
unmakeEventIn (Param x)  = case x of
    Delay xs   -> C.unwords ["delay"   ,C.pack $ show xs]
    MaxTake xs -> C.unwords ["maxtake" ,C.pack $ show xs]
    Start  xs  -> C.unwords ["start"   ,C.pack $ show xs]
unmakeEventIn (Data x) = C.unwords ["data",C.pack $ show x]

-- EventOut
unmakeEventOut :: EventOut -> ByteString
unmakeEventOut eo = case eo of
    Set xs   -> C.unwords ["set", C.pack $ show xs]
    UnSet -> "unset"
    Message xs -> C.unwords ["message", xs]
    Stream xs -> C.unwords ["stream", xs]

makeEventOut :: ByteString -> EventOut
makeEventOut x      = case C.words x of
    []              -> NoEventOut
    ["set", xs]     -> Set $ read $ C.unpack xs
    ["unset"]       -> UnSet
    ["message", xs] -> Message xs
    ["stream", xs]  -> Stream $ read $ C.unpack xs
    _               -> NoEventOut

updateParams :: (Monad m) => Param -> S.StateT Params m ()
updateParams p = do
    ps <- S.get
    let ps' = case p of
            Delay   p' -> ps { delay   = p' }
            MaxTake p' -> ps { maxTake = p' }
            Start   p' -> ps { start   = p' }
    S.put ps'

checkMaxTake :: (Monad m) => Edge (S.StateT Params m) () a a
checkMaxTake = Edge (takeLoop 0)
  where
    takeLoop count a = do
        m <- lift $ S.gets maxTake
        unless (count >= m) $ do
            yield a
            a2 <- await
            takeLoop (count + 1) a2

-- sums a stream
inc :: (Monad m) => Edge (S.StateT Params m) () Double Double
inc = Edge $ push ~> \a -> do
    ps <- lift S.get
    let st = start ps + a
    lift $ updateParams (Start st)
    yield st

-- Edges
dataHandler :: (Monad m) => Edge (S.StateT Params m) () Double EventOut
dataHandler =
        inc
    >>> checkMaxTake
    >>> arr (Stream . C.pack . show)

commandHandler :: (Monad m) => Edge (S.StateT Params m) () Command EventOut
commandHandler = Edge $ push ~> \b -> case b of
    Quit -> return ()
    Stop -> yield UnSet
    Go   -> do
        ps <- lift S.get
        yield $ Set (delay ps)
    Help -> yield $ Message help

paramHandler :: (Monad m) => Edge (S.StateT Params m) () Param x
paramHandler = Edge $ push ~> (lift . updateParams)

eventHandler :: (Monad m) => Edge (S.StateT Params m) () EventIn EventOut
eventHandler = proc e ->
    case e of
        Data    x  -> dataHandler    -< x
        Command b  -> commandHandler -< b
        Param   p  -> paramHandler   -< p
        NoEvent    -> (Edge $ push ~> return) -< ()

main :: IO ()
main = do
    -- Initialize controllers and views
    inCmd  <- makeInput stdinEvent
    outTerminal <- terminalView
    (inTick, outChange) <- ticks
    values <- fromList [1..]

    -- Space the random values according to the ticks
    let inData= (\_ a -> Data a) <$> inTick <*> values

    -- output directing
    let oEventOut = Output $ \e -> case e of
            Stream str  -> send outTerminal str
            Message str -> send outTerminal str
            x           -> send outChange x

    let saveIn = P.tee (packEventIn >-> writeFile "saveintest.txt")
    let saveOut = P.tee (packEventOut >-> writeFile "saveouttest.txt")

    -- Go!
    PS.runSafeT $ (`S.evalStateT` defaultParams) $ runEffect $
            fromInput (inCmd <> inData)
        >-> unsafeHoist lift saveIn
        >-> runEdge eventHandler
        >-> unsafeHoist lift saveOut
        >-> toOutput oEventOut


-- test routines
replayIO :: IO ()
replayIO = do
    -- Initialize controllers and views
    outTerminal <- terminalView
    (_, outChange) <- ticks

    -- output directing
    let oEventOut = Output $ \e -> case e of
            Stream str  -> send outTerminal str
            Message str -> send outTerminal str
            x           -> send outChange x

    let loadIn =     takeLines (readFile "saveintest.txt")
                 >-> unsafeHoist lift unpackEventIn
        saveReplayOut = P.tee (packEventOut >-> writeFile "savereplaytest.txt")

    -- Go!
    PS.runSafeT $ (`S.evalStateT` defaultParams) $ runEffect $
            unsafeHoist lift loadIn
        >-> runEdge eventHandler
        >-> unsafeHoist lift saveReplayOut
        >-> toOutput oEventOut

replayPure :: [EventIn] -> [EventOut]
replayPure eventin =
    runIdentity $ (`S.evalStateT` defaultParams) $
    P.toListM (each eventin >-> runEdge eventHandler)

testReplay :: [ByteString] -> [ByteString] -> Bool
testReplay i r = map unmakeEventOut (replayPure $ map makeEventIn i) == r

test1 :: Bool
test1 = testReplay dataInputBS dataOutputBS

dataInputBS :: [ByteString]
dataInputBS =
    [ "go"
    , "data 1.0"
    , "data 2.0"
    , "data 3.0"
    , "data 4.0"
    , "data 5.0"
    , "data 6.0"
    , "stop"
    , "data 7.0"
    , "start 100.0"
    , "delay 3.0"
    , "go"
    , "data 8.0"
    , "data 9.0"
    , "data 10.0"
    , "data 11.0"
    , "data 12.0"
    , "data 13.0"
    , "help"
    , "data 14.0"
    , "data 15.0"
    , "maxtake 20"
    , "data 16.0"
    , "data 17.0"
    , "data 18.0"
    , "data 19.0"
    , "data 20.0"
    , "data 21.0"
    ]

dataOutputBS :: [ByteString]
dataOutputBS =
    [ "set 1.0"
    , "stream 1.0"
    , "stream 3.0"
    , "stream 6.0"
    , "stream 10.0"
    , "stream 15.0"
    , "stream 21.0"
    , "unset"
    , "stream 28.0"
    , "set 3.0"
    , "stream 108.0"
    , "stream 117.0"
    , "stream 127.0"
    , "stream 138.0"
    , "stream 150.0"
    , "stream 163.0"
    , "message go stop quit help delay maxtake start data"
    , "stream 177.0"
    , "stream 192.0"
    , "stream 208.0"
    , "stream 225.0"
    , "stream 243.0"
    , "stream 262.0"
    , "stream 282.0"
    ]
