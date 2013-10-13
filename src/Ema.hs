
module Ema (
    Ema(..)
  , ema
  , emaSq
  , estd
  ) where

import           Control.Applicative ((<$>), (<*>))
import Control.Foldl (Fold(..))

-- exponential moving average
data Ema = Ema
   { numerator   :: {-# UNPACK #-} !Double
   , denominator :: {-# UNPACK #-} !Double
   }

ema :: Double -> Fold Double Double
ema alpha = Fold step (Ema 0 0) (\(Ema n d) -> n / d)
  where
    step (Ema n d) n' = Ema ((1 - alpha) * n + n') ((1 - alpha) * d + 1)

emaSq :: Double -> Fold Double Double
emaSq alpha = Fold step (Ema 0 0) (\(Ema n d) -> n / d)
  where
    step (Ema n d) n' = Ema ((1 - alpha) * n + n' * n') ((1 - alpha) * d + 1)

estd :: Double -> Fold Double Double
estd alpha = (\s ss -> sqrt (ss - s**2)) <$> ema alpha <*> emaSq alpha
