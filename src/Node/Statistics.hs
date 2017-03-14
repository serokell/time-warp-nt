{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
module Node.Statistics
    ( Statistics(..)
    , PeerStatistics(..)
    , initialStatistics) where

import qualified Mockable.Metrics              as Metrics
import           Data.Map.Strict               (Map)
import qualified Data.Map.Strict               as Map
import           Mockable.SharedAtomic
import           Mockable
import qualified Network.Transport.Abstract    as NT

-- | Statistics concerning traffic at this node.
data Statistics m = Statistics {
      -- | How many handlers are running right now in response to a
      --   remotely initiated connection (whether unidirectional or
      --   bidirectional).
      --   NB a handler may run longer or shorter than the duration of a
      --   connection.
      stRunningHandlersRemote :: !(Metrics.Gauge m)
      -- | How many handlers are running right now which were initiated
      --   locally, i.e. corresponding to bidirectional connections.
    , stRunningHandlersLocal :: !(Metrics.Gauge m)
      -- | Statistics for each peer.
    , stPeerStatistics :: !(Map NT.EndPointAddress (SharedAtomicT m PeerStatistics))
      -- | How many peers are connected.
    , stPeers :: !(Metrics.Gauge m)
      -- | Average number of remotely-initiated handlers per peer.
      --   Also track the average of the number of handlers squared, so we
      --   can quickly compute the variance.
    , stRunningHandlersRemoteAverage :: !(Double, Double)
      -- | Average number of locally-initiated handlers per peer.
      --   Also track the average of the number of handlers squared, so we
      --   can quickly compute the variance.
    , stRunningHandlersLocalAverage :: !(Double, Double)
      -- | Handlers which finished normally. Distribution is on their
      --   running time.
    , stHandlersFinishedNormally :: !(Metrics.Distribution m)
      -- | Handlers which finished exceptionally. Distribution is on their
      --   running time.
    , stHandlersFinishedExceptionally :: !(Metrics.Distribution m)
    }

-- | Statistics when a node is launched.
initialStatistics :: ( Mockable Metrics.Metrics m ) => m (Statistics m)
initialStatistics = do
    !runningHandlersRemote <- Metrics.newGauge
    !runningHandlersLocal <- Metrics.newGauge
    !peers <- Metrics.newGauge
    !handlersFinishedNormally <- Metrics.newDistribution
    !handlersFinishedExceptionally <- Metrics.newDistribution
    return Statistics {
          stRunningHandlersRemote = runningHandlersRemote
        , stRunningHandlersLocal = runningHandlersLocal
        , stPeerStatistics = Map.empty
        , stPeers = peers
        , stRunningHandlersRemoteAverage = (0, 0)
        , stRunningHandlersLocalAverage = (0, 0)
        , stHandlersFinishedNormally = handlersFinishedNormally
        , stHandlersFinishedExceptionally = handlersFinishedExceptionally
        }

-- | Statistics about a given peer.
data PeerStatistics = PeerStatistics {
      -- | How many handlers are running right now in response to connections
      --   from this peer (whether unidirectional or remotely-initiated
      --   bidirectional).
      pstRunningHandlersRemote :: !Int
      -- | How many handlers are running right now for locally-iniaiated
      --   bidirectional connections to this peer.
    , pstRunningHandlersLocal :: !Int
      -- | How many bytes have been received by running handlers for this
      --   peer.
    , pstLiveBytes :: !Int
    }
