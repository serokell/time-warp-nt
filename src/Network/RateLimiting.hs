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
import           Formatting (sformat, shown, (%))
import           Mockable.Class
import           Mockable.SharedAtomic
import           Network.QDisc.Fair (fairQDisc)
import           Network.Transport (EndPointAddress)
import           Network.Transport.TCP (QDisc(..), simpleUnboundedQDisc)
import           System.Wlog (WithLogger, logWarning)

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
    :: ( Mockable SharedAtomic m
       , WithLogger m)
    => (forall t. m t -> IO t)
    -> Int -- ^ Maximum in-flight bytes per peer.
    -> m (RateLimiting m)
rateLimitingBlocking liftIO maxBytesPerPeer = do
    locks <- newSharedAtomic Map.empty
    return RateLimiting
        { rlQDisc = fairQDisc $ \peer -> liftIO $ do
            lockMap <- readSharedAtomic locks
            case Map.lookup peer lockMap of
                Nothing -> do
                    logWarning $ sformat ("rateLimitingBlocking.rlQDisc: could not find peer "%shown%" in rlLocks") peer
                    return Nothing
                Just lock -> readSharedAtomic lock
        , rlLockByBytes = \peer bytes -> do
            lockMap <- readSharedAtomic locks
            case Map.lookup peer lockMap of
                Nothing ->
                    logWarning $ sformat ("rateLimitingBlocking.rlLockByBytes: could not find peer "%shown%" in rlLocks") peer
                Just mvar -> if bytes >= maxBytesPerPeer
                             then void (tryTakeSharedAtomic mvar)
                             else void (tryPutSharedAtomic mvar Nothing)
        , rlNewLock = \peer -> void $ modifySharedAtomic locks $ \lockMap -> do
                newLock <- newSharedAtomic Nothing
                return (Map.insert peer newLock lockMap, ())
        , rlRemoveLock = \peer -> void $ modifySharedAtomic locks $ \lockMap ->
                return (Map.delete peer lockMap, ())
        }
{-# NOINLINE rateLimitingBlocking #-}
