{-# LANGUAGE TypeFamilies, RankNTypes, OverloadedStrings #-}

module File
    ( readFile
    , writeFile
    , takeLines
    ) where

import Prelude hiding (readFile, writeFile)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import Pipes
import qualified Pipes.Prelude as P
import qualified Pipes.Safe       as PS
import qualified Pipes.ByteString as PB
import           System.IO (openFile, hClose, IOMode(..))
import qualified Pipes.Parse      as PP

-- file helpers
readFile :: FilePath
	 -> Producer' ByteString (PS.SafeT IO) ()
readFile file = PS.bracket
    (do h <- openFile file ReadMode
	C.putStrLn $ C.concat ["{",C.pack file," open}"]
	return h )
    (\h -> do
	  hClose h
	  C.putStrLn $ C.concat ["{",C.pack file," closed}"] )
    PB.fromHandle

writeFile :: FilePath
	 -> Consumer' ByteString (PS.SafeT IO) ()
writeFile file = PS.bracket
    (do h <- openFile file WriteMode
	C.putStrLn $ C.concat ["{",C.pack file," open}"]
	return h )
    (\h -> do
	  hClose h
	  C.putStrLn $ C.concat ["{",C.pack file," closed}"])
    PB.toHandle

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
