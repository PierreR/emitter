{-# LANGUAGE RankNTypes #-}

module Time (

    -- * standard UTC time handlers
    -- $UTC helpers
      defaultFormatTime
    , defaultParseTime

    -- * Re-exports
    -- $reexports
    , UTCTime(..)
    , getCurrentTime
    , diffUTCTime

    ) where

import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import           Data.Fixed (Milli)
import           Data.Time.Clock ( getCurrentTime, diffUTCTime, UTCTime(..))
import           Data.Time.Format ( formatTime, parseTime )
import           Data.Time.LocalTime (todSec, timeToTimeOfDay)
import           System.Locale ( defaultTimeLocale )

-- UTC
picoToMilli :: forall a. RealFrac a => a -> Milli
picoToMilli n = fromIntegral (round $ n * 1000 :: Integer) / 1000 :: Milli

defaultFormatTime :: UTCTime -> ByteString
defaultFormatTime t = C.pack $ f ++ p
  where
    s = picoToMilli $ todSec $ timeToTimeOfDay $ utctDayTime t
    f = formatTime defaultTimeLocale "%F %H:%M:%S." t
    p = drop 2 $ show $ s - fromIntegral (floor s :: Integer)

defaultParseTime :: ByteString -> Maybe UTCTime
defaultParseTime = parseTime defaultTimeLocale "%F %H:%M:%S%Q" . C.unpack
