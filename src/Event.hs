{-# LANGUAGE TypeFamilies, RankNTypes, OverloadedStrings #-}

module Event
    ( -- classes
      Event
    , TEvent
    , pack
    , unpack
    , post
    , pack'
    , unpack'

      -- Controllers and Views
    , fromList
    , makeInput
    , makeInputRight
    , wireRight
    , stdinEvent
    , stdoutView
    , toFile
    , fromFile
    , fromFileRight

      -- effectful boxes
    , delay
    , pause
    , outsidePause

      -- timed event
    , packDefaultTime
    , unpackDefaultTime
    , stamp
    , addStamp
    , toFileAddTime
    , timedEvent
    ) where

import           Control.Applicative ((<$>), (<*>), pure)
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (async, link)
import           Control.Concurrent.STM (newTVarIO, readTVar, writeTVar, retry)
import           Control.Error (isLeft, isJust, fromMaybe, hush)
import           Control.Monad (liftM, when, forever, void, unless)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import           Data.Maybe (fromJust)
import           Pipes
import           Pipes.Concurrent
import qualified Pipes.Prelude as P
import           Pipes.Safe (SafeT, runSafeT)
import           Prelude hiding (readFile, writeFile)

import           File
import           Time (defaultFormatTime, defaultParseTime, getCurrentTime, UTCTime(..), diffUTCTime)

-- the Event class
class (Eq a, Show a, Read a) => Event a where
    pack :: a -> ByteString
    pack = C.pack . show

    unpack :: ByteString -> Either ByteString a
    unpack b = case reads $ C.unpack b of
        [] -> Left b
        [(x, "")]  -> Right x

    pack' :: a -> ByteString
    pack' e = C.snoc (pack e) '\n'

    unpack' :: ByteString -> Either ByteString a
    unpack' b = unpack $ C.takeWhile (/= '\n') b

    post :: Output a -> a -> IO Bool
    post o e = atomically $ send o e

    open :: Input a -> IO (Maybe a)
    open i = atomically $ recv i

    wire :: Input a -> (a -> b) -> Output b -> IO ()
    wire i f b = runEffect $ fromInput i >-> P.map f >-> toOutput b

-- the TEvent class
data TEvent a = TEvent
    { _time :: Maybe UTCTime
    , _event :: a
    } deriving (Show, Eq, Read)

instance (Show a, Eq a, Read a) => Event (TEvent a)

-- Controllers and views
fromList :: [a] -> IO (Input a)
fromList as = do
    (o, i) <- spawn Single
    a <- async $ runEffect $ each as >-> toOutput o
    link a
    return i

makeInput :: IO a -> IO (Input a)
makeInput p = do
    (o, i) <- spawn Unbounded
    a <- async $ runEffect $ lift p >~ toOutput o
    link a
    return i

makeInputRight :: (Show a) => IO (Either ByteString a) -> IO (Input a)
makeInputRight p = do
    (o, i) <- spawn Unbounded
    a <- async $ runEffect $
         lift p >~
         -- P.tee P.print >->
         P.tee (P.filter isLeft >-> P.print) >->
         P.map hush >->
         P.filter isJust >->
         P.map fromJust >->
         toOutput o
    link a
    return i

wireRight :: (Show a) => Input (Either ByteString a) -> IO (Input a)
wireRight up = do
    (o, down) <- spawn Unbounded
    a <- async $ runEffect $
         fromInput up >->
         -- P.tee P.print >->
         P.tee (P.filter isLeft >-> P.print) >->
         P.map hush >->
         P.filter isJust >->
         P.map fromJust >->
         toOutput o
    link a
    return down


stdinEvent :: (Read a) => (Event a) => IO (Either ByteString a)
stdinEvent = liftM unpack C.getLine

stdoutView :: (Show a) => IO (Output a)
stdoutView = do
    (os, is) <- spawn Unbounded
    a <- async $ runEffect $ fromInput is >-> P.print
    link a
    return os

-- event file helpers

-- lift is tricky with a PS.SafeT in the mix
lift' :: forall b a (m :: * -> *) y. Monad m =>
               (a -> y) -> Pipe a y m b
lift' f = forever (await >>= yield . f)

toFile :: forall a. Event a =>
    FilePath -> Consumer a (SafeT IO) ()
toFile fp = lift' pack' >-> writeFile fp

fromFile :: (Read a, Event a) =>
    FilePath -> Producer (Either ByteString a) (SafeT IO) ()
fromFile fp = takeLines (readFile fp) >-> lift' unpack'

fromFileRight :: (Read a, Event a) =>
    FilePath -> Producer a (SafeT IO) ()
fromFileRight fp = takeLines (readFile fp) >->
               -- P.tee P.print >->
               lift' unpack' >->
               P.tee (P.filter isLeft >-> P.print) >->
               P.map hush >->
               P.filter isJust >->
               P.map fromJust

-- effectful boxes
delay :: Double -> IO (Input (), Output Double)
delay dInitial = do
    (o, i) <- spawn Single
    tvar   <- newTVarIO dInitial
    let delay' = do
            x <- atomically $ readTVar tvar
            threadDelay $ truncate $ 1000000 * x
            return ()
    a <- async $ runEffect $ lift delay' >~ toOutput o
    link a
    let oSetDelay = Output $ \d -> writeTVar tvar d >> return True
    return (i, oSetDelay)

pause :: Bool -> IO (Input (), Output Bool)
pause pInitial = do
    (o, i) <- spawn Single
    tvar   <- newTVarIO pInitial
    let pause' =
            atomically $ do
                x <- readTVar tvar
                when x retry
    a <- async $ runEffect $ lift pause' >~ toOutput o
    link a
    let oSetPause = Output $ \b -> writeTVar tvar b >> return True
    return (i, oSetPause)

outsidePause :: Bool -> Input a -> IO (Input a, Output Bool)
outsidePause pInitial inBox = do
    (oSwitch, iSwitch) <- spawn Single
    (oStream, iStream) <- spawn Single
    tvar   <- newTVarIO pInitial
    unless pInitial $
        atomically $ void $ send oSwitch ()
        -- putStrLn "()"
    let pausedStream = (\_ a -> a) <$> iSwitch <*> inBox

    a <- async $ forever $ runEffect $ fromInput pausedStream
         >-> forever (do
                  s <- await
                  p <- lift $ atomically $ readTVar tvar
                  lift $ atomically $ unless p $ void $ send oSwitch ()
                  yield s)
         >-> toOutput oStream
    link a

    let oSetPause = Output $ \b -> do
            prior <- readTVar tvar
            when (prior /= b) $ do
                when b $ void $ recv iSwitch
                writeTVar tvar b
            return True
    return (iStream, oSetPause)

-- timed event
packDefaultTime :: (Event a) => TEvent a -> ByteString 
packDefaultTime e = C.concat [ fromMaybe "" $ defaultFormatTime <$> _time e
                       , C.singleton ','
                       , C.pack $ show $ _event e]

unpackDefaultTime :: (Event a) => ByteString -> Either ByteString (TEvent a)
unpackDefaultTime b = TEvent <$> pure t' <*> unpack e
      where
        [t,e] = C.splitWith (== ',') b
        t' = defaultParseTime t

stamp :: (Event a) => a -> IO (TEvent a)
stamp e = do
        t <- getCurrentTime
        return $ TEvent (Just t) e

addStamp :: (Event a) => Pipe a (TEvent a) IO ()
addStamp = forever $ do
    s <- await
    e <- lift $ stamp s
    yield e

toFileAddTime :: forall a. Event a =>
    FilePath -> Consumer a (SafeT IO) ()
toFileAddTime fp = hoist lift addStamp >-> lift' pack' >-> writeFile fp

timedEvent :: Producer (TEvent a) (SafeT IO) ()
                  -> IO (Input a)
timedEvent p = do
    (o,iEvent) <- spawn Unbounded
    a <- async $ runSafeT $ initThenLoop o
    link a
    return iEvent
  where
    initThenLoop o = do
        one <- next p
        case one of
            Left _ -> return ()
            Right (e,p') -> do
                t0 <- lift getCurrentTime
                runSafeT $ runEffect $ yield (_event e) >-> toOutput o
                lift $ loop p' o (_time e) t0
        return ()
    loop p'' o' ts0 t0 = do
        n <- runSafeT $ next p''
        case n of
            Left _ -> return ()
            Right (e',p''') -> do
                t' <- getCurrentTime
                let delayTime = (-) <$>
                            (diffUTCTime <$> _time e' <*> ts0) <*>
                            (Just $ diffUTCTime t'  t0)
                threadDelay $ truncate $ 1000000 * fromMaybe 0 delayTime
                runSafeT $ runEffect $ yield (_event e') >-> toOutput o'
                loop p''' o' ts0 t0
