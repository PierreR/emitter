{-# LANGUAGE Arrows #-}

{-

- deal with seed
- unpack stuff
- save event stream
- business logic test

-}

module Main where

import           Control.Applicative ((<$>), (<*>))
import           Control.Arrow ((>>>), arr)
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.STM (newTVarIO, readTVar, writeTVar, retry)
import qualified Control.Foldl as L
import           Control.Monad (unless, liftM)
-- import           Control.Monad.IO.Class (MonadIO(liftIO))
import qualified Control.Monad.Trans.State.Strict as S
-- import           Control.Monad.Trans.Class (lift)
import           Data.Monoid ((<>))
import           Data.Random.Normal (mkNormals)

import           Pipes
import           Pipes.Arrow (Edge(Edge, unEdge))
import           Pipes.Core (push)
import           Pipes.Concurrent
import qualified Pipes.Prelude as P

-- constants
seed :: Int
seed = 42

-- data types
-- TODO: UNPACK stuff
data Param
    = Delay   {-# UNPACK #-} !Double
    | MaxTake {-# UNPACK #-} !Int
    | Start   {-# UNPACK #-} !Double
    | Drift   {-# UNPACK #-} !Double
    | Sigma   {-# UNPACK #-} !Double
    | Dt      {-# UNPACK #-} !Double
    | Ema1    {-# UNPACK #-} !Double
    | Ema2    {-# UNPACK #-} !Double
    deriving (Show)

data Params = Params
    { delay   :: {-# UNPACK #-} !Double
    , maxTake :: {-# UNPACK #-} !Int
    , start   :: {-# UNPACK #-} !Double
    , drift   :: {-# UNPACK #-} !Double
    , sigma   :: {-# UNPACK #-} !Double
    , dt      :: {-# UNPACK #-} !Double
    , ema1    :: {-# UNPACK #-} !Double
    , ema2    :: {-# UNPACK #-} !Double
    } deriving (Show)

defaultParams :: Params
defaultParams = Params
    { delay   = 1.0  -- delay in seconds
    , maxTake = 1000 -- maximum number of stream elements
    , start   = 0    -- random walk start
    , drift   = 0    -- random walk drift
    , sigma   = 1    -- volatility
    , dt      = 1    -- time grain
    , ema1    = 0    -- ema parameter (0=latest, 1=average)
    , ema2    = 0.5  -- ema parameter
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
    , "drift"
    , "sigma"
    , "dt"
    , "ema1"
    , "ema2"
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
    Drift  xs  -> unwords ["drift"   ,show xs]
    Sigma  xs  -> unwords ["sigma"   ,show xs]
    Dt     xs  -> unwords ["dt"      ,show xs]
    Ema1   xs  -> unwords ["ema1"    ,show xs]
    Ema2   xs  -> unwords ["ema2"    ,show xs]
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
    ["drift"  , xs] -> Param $ Drift   $ read xs
    ["sigma"  , xs] -> Param $ Sigma   $ read xs
    ["dt"     , xs] -> Param $ Dt      $ read xs
    ["ema1"   , xs] -> Param $ Ema1    $ read xs
    ["ema2"   , xs] -> Param $ Ema2    $ read xs
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
            Drift   p' -> ps { drift   = p' }
            Sigma   p' -> ps { sigma   = p' }
            Dt      p' -> ps { dt      = p' }
            Ema1    p' -> ps { ema1    = p' }
            Ema2    p' -> ps { ema2    = p' }
    S.put ps'

takeMax :: (Monad m) => Edge (S.StateT Params m) () a a
takeMax = Edge (takeLoop 0)
  where
    takeLoop count a = do
        m <- lift $ S.gets maxTake
        unless (count >= m) $ do
            yield a
            a2 <- await
            takeLoop (count + 1) a2

-- turns a random stream into a random walk stream
walker :: (Monad m) => Edge (S.StateT Params m) () Double Double
walker = Edge $ push ~> \a -> do
    ps <- lift S.get
    let st = start ps + drift ps * dt ps + sigma ps * sqrt (dt ps) * a
    lift $ updateParams (Start st)
    yield st

emaStats :: (Monad m) => Edge (S.StateT Params m) r Double (Double, Double)
emaStats = Edge $ \a -> do
    ps <- lift S.get
    case (,) <$> ema (ema1 ps) <*> ema (ema2 ps) of
        L.Fold step begin done -> push a >-> P.scan step begin done

dataHandler :: (Monad m) => Edge (S.StateT Params m) () Double EventOut
dataHandler =
        walker
    >>> takeMax
    >>> emaStats
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
    randomValues <- fromList (mkNormals seed)

    -- Space the random values according to the ticks
    let inData= (\_ a -> Data a) <$> inTick <*> randomValues

    -- 'totalPipe' is the pure kernel of business logic
    let totalPipe = await >>= unEdge total

    -- Go!
    (`S.evalStateT` defaultParams) $ runEffect $
            fromInput (inCmd <> inData)
        >-> totalPipe
        >-> toOutput (outTerminal <> outChange)

-- exponential moving average
data Ema = Ema
   { numerator   :: {-# UNPACK #-} !Double
   , denominator :: {-# UNPACK #-} !Double
   }

ema :: Double -> L.Fold Double Double
ema alpha = L.Fold step (Ema 0 0) (\(Ema n d) -> n / d)
  where
    step (Ema n d) n' = Ema ((1 - alpha) * n + n') ((1 - alpha) * d + 1)

emaSq :: Double -> L.Fold Double Double
emaSq alpha = L.Fold step (Ema 0 0) (\(Ema n d) -> n / d)
  where
    step (Ema n d) n' = Ema ((1 - alpha) * n + n' * n') ((1 - alpha) * d + 1)

estd :: Double -> L.Fold Double Double
estd alpha = (\s ss -> sqrt (ss - s**2)) <$> ema alpha <*> emaSq alpha
