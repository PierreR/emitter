{-# LANGUAGE ExistentialQuantification, TypeFamilies #-}

import Control.Applicative
import Control.Monad (forever, replicateM_)
import qualified Data.ByteString.Lazy as BL
import qualified Control.Foldl as L
import Pipes
import qualified Pipes.Prelude as P
import Data.Binary
import qualified Filesystem as F
import qualified Filesystem.Path as F
import Prelude hiding (length, sum)

-- A fold that can be saved and resumed, with a default starting value
data Scan a b = forall s
    .  (Binary s)
    => Scan { runScan :: s -> L.Fold a (s, b), def :: s }

instance Functor (Scan a) where
    fmap f (Scan x d) = Scan (\s -> fmap (fmap f) (x s)) d

instance Applicative (Scan a) where
    pure b = Scan (\() -> pure ((), b)) ()
    (Scan mf df) <*> (Scan mx dx) =
        Scan (\(s1, s2) -> munge <$> mf s1 <*> mx s2) (df, dx)
      where
        munge (s1', f) (s2', x) = ((s1', s2'), f x)

length :: Scan a Int
length = Scan (\n0 -> L.Fold (\n _ -> n + 1) n0 (\n -> (n, n))) 0

sum :: Scan Int Int
sum = Scan (\n0 -> L.Fold (+) n0 (\n -> (n, n))) 0

average :: Scan Int (Maybe Int)
average = munge <$> sum <*> length
  where
    munge x y = if (y == 0) then Nothing else Just (div x y)

data Aggregate = Aggregate { representation :: BL.ByteString, numEvents :: Int }

{-| Convert a 'Scan' to a 'Pipe', given a starting state

    If you supply 'Nothing' this will begin the fold from its default starting
    state.  If you supply a previously serialized state (i.e. a 'BL.ByteString')
    then it will resume from where it previously left off.

    This outputs results alongside the currently serialized state (i.e. a
    'BL.ByteString').
-}
scan
    :: (Monad m)
    => Scan a b -> Maybe BL.ByteString-> Pipe a (BL.ByteString, b) m r
scan (Scan k d) mbs = do
    let (n, s) = case mbs of
            Nothing -> ((0 :: Int), d)
            Just bs -> decode bs
        length' = L.Fold (\x _ -> x + 1) n id
    case ((,) <$> k s <*> length') of
        L.Fold step begin done -> do
            P.drop n
                >-> P.scan step begin done
                >-> P.map (\((s, b), n) -> (encode (n, s), b))

{-| High-level interface to 'scan', which automatically reads and writes data
    to a file with the given frequency
-}
scan' :: Scan a b -> F.FilePath -> Int -> Pipe a b IO r
scan' s file n = do
    exists <- lift (F.isFile file)
    mbs    <- if exists
        then lift $ fmap (Just . BL.fromStrict) (F.readFile file)
        else return Nothing
    scan s mbs >-> save
  where
    save = forever $ do
        P.take (n - 1) >-> P.map snd
        (bs, b) <- await
        lift $ F.writeFile file (BL.toStrict bs)
        yield b
