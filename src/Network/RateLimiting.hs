{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
module Network.RateLimiting where

import           Control.Monad (void)
import qualified Data.Map.Strict as Map
import           Formatting (sformat, shown, (%))
import           Mockable.Class
import           Mockable.SharedAtomic
import           Network.QDisc.Fair (fairQDisc)
import           Network.Transport (EndPointAddress)
import           Network.Transport.TCP (QDisc(..), simpleUnboundedQDisc)
import           System.Wlog (WithLogger, logWarning)

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

rateLimitingUnbounded :: Monad m => RateLimiting m
rateLimitingUnbounded = NoRateLimiting simpleUnboundedQDisc

rateLimitingBlocking
    :: ( Mockable SharedAtomic m
       , WithLogger m)
    => (forall t. m t -> IO t)
    -> Int
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
