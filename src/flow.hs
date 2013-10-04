{-# LANGUAGE Arrows #-}

{-

- save event stream
- pure logic test

-}

module Main where

import           Control.Applicative ((<$>), (<*>))
import           Control.Arrow ((>>>), arr)
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.STM (newTVarIO, readTVar, writeTVar, retry)
import           Control.Monad (unless, liftM)
-- import           Control.Monad.IO.Class (MonadIO(liftIO))
import qualified Control.Monad.Trans.State.Strict as S
-- import           Control.Monad.Trans.Class (lift)
import           Data.Monoid ((<>))

import           Pipes
import           Pipes.Arrow (Edge(Edge, unEdge))
import           Pipes.Core (push)
import           Pipes.Concurrent
import qualified Pipes.Prelude as P

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

data Command = Quit | Stop | Go | Help deriving (Show)

data EventIn = Data Double | Command Command | Param Param deriving (Show)

data EventOut = Set Double | UnSet | ShowHelp | Stream String deriving (Show)

-- Controllers and Views
help :: String
help = unwords
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
stdinEvent = liftM makeEvent getLine

userInput :: IO (Input EventIn)
userInput = do
    (om, im) <- spawn Unbounded
    a <- async $ runEffect $ lift stdinEvent >~ toOutput om
    link a
    return im

makeString :: EventIn -> String
makeString (Command x) = case x of
    Go   -> "go"
    Stop -> "stop"
    Quit -> "quit"
    Help -> "help"
makeString (Param x)  = case x of
    Delay xs   -> unwords ["delay"   ,show xs]
    MaxTake xs -> unwords ["maxtake" ,show xs]
    Start  xs  -> unwords ["start"   ,show xs]
makeString (Data x) = unwords ["data",show x]

makeEvent :: String -> EventIn
makeEvent x      = case words x of
    ["go"]          -> Command Go
    ["stop"]        -> Command Stop
    ["quit"]        -> Command Quit
    ["help"]        -> Command Help
    ["data"   , xs] -> Data  $ read xs
    ["delay"  , xs] -> Param $ Delay   $ read xs
    ["maxtake", xs] -> Param $ MaxTake $ read xs
    ["start"  , xs] -> Param $ Start   $ read xs
    _               -> Command Help

terminalView :: IO (Output EventOut)
terminalView = do
    (os, is) <- spawn Unbounded
    a <- async $ runEffect $ fromInput is >-> P.print
    link a
    return $ Output $ \e ->
        case e of
            Stream str -> send os str
            ShowHelp   -> send os help
            _          -> return True

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

-- All the pure logic.  Note that none of these use 'IO'
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

dataHandler :: (Monad m) => Edge (S.StateT Params m) () Double EventOut
dataHandler =
        inc
    >>> checkMaxTake
    >>> arr (Stream . show)

commandHandler :: (Monad m) => Edge (S.StateT Params m) () Command EventOut
commandHandler = Edge $ push ~> \b -> case b of
    Quit -> return ()
    Stop -> yield UnSet
    Go   -> do
        ps <- lift S.get
        yield $ Set (delay ps)
    Help -> yield ShowHelp

paramHandler :: (Monad m) => Edge (S.StateT Params m) () Param x
paramHandler = Edge $ push ~> (lift . updateParams)

total :: (Monad m) => Edge (S.StateT Params m) () EventIn EventOut
total = proc e ->
    case e of
        Data    x  -> dataHandler    -< x
        Command b  -> commandHandler -< b
        Param   p  -> paramHandler   -< p

main :: IO ()
main = do
    -- Initialize controllers and views
    inCmd  <- userInput
    outTerminal <- terminalView
    (inTick, outChange) <- ticks
    values <- fromList [1..]

    -- Space the random values according to the ticks
    let inData= (\_ a -> Data a) <$> inTick <*> values

    -- 'totalPipe' is the pure kernel of business logic
    let totalPipe = await >>= unEdge total

    -- Go!
    (`S.evalStateT` defaultParams) $ runEffect $
            fromInput (inCmd <> inData)
        >-> totalPipe
        >-> toOutput (outTerminal <> outChange)
