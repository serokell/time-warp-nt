module Network.Discovery.Static (

      staticDiscovery

    ) where

import Network.Discovery.Abstract
import Network.Transport.Abstract
import Data.Set (Set)
import Data.Void

staticDiscovery :: Applicative m => Set EndPointAddress -> NetworkDiscovery Void m
staticDiscovery set = NetworkDiscovery {
      knownPeers = pure set
    , discoverPeers = pure (Right mempty)
    }
