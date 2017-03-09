{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
module Network.RateLimiting
       ( -- * Types
         RateLimiting(..)
       , rlLift
         -- * Rate-limiting strategies
       , rateLimitingUnbounded
       , rateLimitingFair
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

-- | A rate-limiting strategy.
--
-- This includes a 'QDisc' to govern how incoming requests are
-- enqueued and dequeued, and also the possibility to block or delay
-- requests from a peer depending on the number of in-flight bytes.
data RateLimiting m =
      NoRateLimiting !(forall t. IO (QDisc t))
    | RateLimiting
      { rlQDisc :: forall t. IO (QDisc t)
      , rlLockByBytes
            :: (Mockable SharedAtomic m)
            => EndPointAddress
            -> Int
            -> m ()
      , rlNewLock :: EndPointAddress -> m ()
      , rlRemoveLock :: EndPointAddress -> m ()
      }

rlLift :: (Mockable SharedAtomic m, MonadTrans t) => RateLimiting m -> RateLimiting (t m)
rlLift (NoRateLimiting qDisc) = NoRateLimiting qDisc
rlLift RateLimiting{..} = RateLimiting
    { rlQDisc = rlQDisc
    , rlLockByBytes = \peer bytes -> lift $ rlLockByBytes peer bytes
    , rlNewLock = lift . rlNewLock
    , rlRemoveLock = lift . rlRemoveLock
    }

-- | The simplest rate-limiting procedure uses an unbounded queue, and
-- performs no rate limiting at all.
rateLimitingUnbounded :: Monad m => RateLimiting m
rateLimitingUnbounded = NoRateLimiting simpleUnboundedQDisc

-- | Ensures fariness in queueing requests from different peers, but
-- does no rate-limiting.
rateLimitingFair :: Monad m => RateLimiting m
rateLimitingFair = NoRateLimiting (fairQDisc (const $ return Nothing))

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
rateLimitingBlocking liftIO maxBytesPerPeer =
    rateLimitingDamping liftIO (const Nothing) (Just maxBytesPerPeer)

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
rateLimitingDamping liftIO dampingFunction mThreshold = do
    locks <- newSharedAtomic Map.empty
    return RateLimiting
        { rlQDisc = fairQDisc $ \peer -> liftIO $ do
            lockMap <- readSharedAtomic locks
            case Map.lookup peer lockMap of
                Nothing -> return Nothing
                Just lock -> readSharedAtomic lock
        , rlLockByBytes = \peer bytes -> do
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
