{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
module Network.RateLimiting
       ( -- * Types
         RateLimiting(..)
       , rlLift
         -- * Rate-limiting strategies
       , noRateLimitingUnbounded
       , noRateLimitingFair
       , rateLimitingBlocking
       , rateLimitingDamping
       ) where

import           Control.Monad (void)
import           Control.Monad.Trans.Class
import qualified Data.Map.Strict as Map
import           Data.Maybe (isJust, fromJust)
import           Data.Time.Units (Microsecond)
import           Mockable.Class
import           Mockable.SharedAtomic
import           Network.QDisc.Fair (fairQDisc)
import           Network.Transport (EndPointAddress)
import           Network.Transport.TCP (QDisc(..), simpleUnboundedQDisc)
import           Node.Statistics (PeerStatistics (..))

-- | A rate-limiting strategy.
--
-- This includes a 'QDisc' to govern how incoming requests are
-- enqueued and dequeued, and also the possibility to block or delay
-- requests from a peer depending on the 'PeerStatistics' of that peer.
--
-- Each peer will get a "lock" that determines whether a new request
-- will be immediately enqueued, delayed by a fixed time, or blocked
-- until the 'PeerStatistics' for that peer change.
data RateLimiting m = RateLimiting
      { -- | `QDisc` used for rate limiting.
        rlQDisc :: forall t. IO (QDisc t)
        -- | Change the state of the lock for a given peer, depending
        -- on the 'PeerStatistics' for this peer.  To be called when
        -- the statistics changes.
      , rlAdjustLock
            :: (Mockable SharedAtomic m)
            => EndPointAddress
            -> PeerStatistics
            -> m ()
        -- | Register a lock for a new peer.  This will be called when
        -- a new peer connects
      , rlNewLock :: EndPointAddress -> m ()
        -- | Unregister the lock for a peer.  To be called when the
        -- last handler of a peer is finished.
      , rlRemoveLock :: EndPointAddress -> m ()
      }

rlLift :: (Mockable SharedAtomic m, MonadTrans t) => RateLimiting m -> RateLimiting (t m)
rlLift RateLimiting{..} = RateLimiting
    { rlQDisc = rlQDisc
    , rlAdjustLock = \peer peerStats -> lift $ rlAdjustLock peer peerStats
    , rlNewLock = lift . rlNewLock
    , rlRemoveLock = lift . rlRemoveLock
    }

noRateLimiting :: Monad m => (forall t. IO (QDisc t)) -> RateLimiting m
noRateLimiting qDisc = RateLimiting
    { rlQDisc = qDisc
    , rlAdjustLock = const . const . return $ ()
    , rlNewLock = const . return $ ()
    , rlRemoveLock = const . return $ ()
    }

-- | The simplest rate-limiting procedure uses an unbounded queue, and
-- performs no rate limiting at all.
noRateLimitingUnbounded :: Monad m => RateLimiting m
noRateLimitingUnbounded = noRateLimiting simpleUnboundedQDisc

-- | Ensures fariness in queueing requests from different peers, but
-- does no rate-limiting.
noRateLimitingFair :: Monad m => RateLimiting m
noRateLimitingFair = noRateLimiting (fairQDisc (const $ return Nothing))

-- | A 'RateLimiting' that actually does rate-limiting.
--
-- As soon as the number of in-flight bytes (bytes from a request that
-- has been received but not yet finished) from a given peer passes a
-- given threshold, further messages from that peer will be blocked,
-- until the number of in-flight bytes drops below the threshold
-- again.
rateLimitingBlocking
    :: (Mockable SharedAtomic m)
    => (forall t. m t -> IO t)
    -> Int -- ^ Maximum in-flight bytes per peer.
    -> m (RateLimiting m)
rateLimitingBlocking lowerIO maxBytesPerPeer =
    rateLimitingDamping lowerIO (const Nothing) (Just maxBytesPerPeer)

-- | rate-limiting strategy that can delay or block traffic, depending
-- on the number of in-flight bytes.
rateLimitingDamping
    :: (Mockable SharedAtomic m)
    => (forall t. m t -> IO t)
    -> (Int -> Maybe Microsecond)
    -- ^ Delay, as a function of the number of
    -- in-flight bytes ('Nothing' means no delay).
    -> Maybe Int
    -- ^ If given, further messages will be blocked
    -- if the number of in-flight bytes passes this threshold.
    -> m (RateLimiting m)
rateLimitingDamping lowerIO dampingFunction mThreshold = do
    locks <- newSharedAtomic Map.empty
    return RateLimiting
        { rlQDisc = fairQDisc $ \peer -> lowerIO $ do
            lockMap <- readSharedAtomic locks
            case Map.lookup peer lockMap of
                Nothing -> return Nothing
                Just lock -> readSharedAtomic lock
        , rlAdjustLock = \peer peerStats -> do
            let bytes = pstLiveBytes peerStats
            lockMap <- readSharedAtomic locks
            case Map.lookup peer lockMap of
                Nothing -> return ()
                Just mvar ->
                    if isJust mThreshold && fromJust mThreshold < bytes
                        then void (tryTakeSharedAtomic mvar)
                        else void (tryPutSharedAtomic mvar (dampingFunction bytes))
        , rlNewLock = \peer -> void $ modifySharedAtomic locks $ \lockMap -> do
                newLock <- newSharedAtomic Nothing
                return (Map.insert peer newLock lockMap, ())
        , rlRemoveLock = \peer -> void $ modifySharedAtomic locks $ \lockMap ->
                return (Map.delete peer lockMap, ())
        }
{-# NOINLINE rateLimitingDamping #-}
