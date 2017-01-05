{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE StandaloneDeriving  #-}

module Network.Discovery.Transport.Kademlia
       ( K.Node (..)
       , K.Peer (..)
       , KademliaDiscoveryErrorCode (..)
       , kademliaDiscovery
       , KIdentifier (..)
       , kademliaDiscoveryExposeInternals
       , KademliaDiscovery
       , kdInstance
       , kdEndPointAddresses
       , kdDiscovery
       , makeKIdentifier
       , makeKIdentifierPaddedTrimmed
       , KSerialize(..)
       ) where

import qualified Control.Concurrent.STM      as STM
import qualified Control.Concurrent.STM.TVar as TVar
import           Control.Monad               (forM)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Data.Binary                 (Binary, get, put, decodeOrFail, encode)
import           Data.Binary.Get             (getByteString)
import           Data.Binary.Put             (putByteString)
import qualified Data.ByteString             as BS
import qualified Data.ByteString.Lazy        as BL
import qualified Data.Map.Strict             as M
import qualified Data.Set                    as S
import           Data.Typeable               (Typeable)
import           Data.Word                   (Word8)
import           Data.Proxy                  (Proxy(Proxy))
import           GHC.Generics                (Generic)
import           GHC.TypeLits                (Nat, KnownNat, natVal)
import qualified Network.Kademlia            as K
import           Network.Discovery.Abstract
import           Network.Transport

-- | A ByteString indexed by the number of bytes.
--   Construct it using 'makeKIdentifier'.
newtype KIdentifier (bytes :: Nat) = KIdentifier {
      getKIdentifier :: BS.ByteString
    }

deriving instance Show (KIdentifier bytes)
deriving instance Eq (KIdentifier bytes)
deriving instance Ord (KIdentifier bytes)

-- | Make a 'KIdentifier' from a 'ByteString'. It must be precisely 'bytes'
--   bytes in length.
makeKIdentifier
    :: forall bytes .
       ( KnownNat bytes )
    => Proxy bytes
    -> BS.ByteString
    -> Either String (KIdentifier bytes)
makeKIdentifier _ bs = case K.fromBS bs of
    Left str -> Left str
    Right (it, remainder) ->
        if BS.null remainder
        then Right it
        else Left "KIdentifier is too long"

-- | Make a 'KIdentifier' from a 'ByteString', handling too-short or too-long
--   by respectively right-padding or right-trimming it.
makeKIdentifierPaddedTrimmed
    :: forall bytes .
       ( KnownNat bytes )
    => Proxy bytes
    -> Word8
    -> BS.ByteString
    -> KIdentifier bytes
makeKIdentifierPaddedTrimmed proxyBytes pad bs
    | missingBytes == 0 =
          let Right kid = makeKIdentifier proxyBytes bs in kid
    | missingBytes < 0 =
          let Right kid = makeKIdentifier proxyBytes (BS.take bytesVal bs) in kid
    | missingBytes > 0 =
          let Right kid = makeKIdentifier proxyBytes (BS.append bs (BS.pack (take missingBytes (repeat pad)))) in kid
    | otherwise = error "makeKIdentifierPaddedTrimmed: impossible"
    where
    bytesVal :: Int
    bytesVal = fromIntegral (natVal proxyBytes)
    missingBytes = bytesVal - BS.length bs

instance ( KnownNat bytes ) => K.Serialize (KIdentifier bytes) where
    toBS (KIdentifier bs) = bs
    fromBS bs = go ([], bs) (natVal (Proxy :: Proxy bytes))
        where
        go (words', remainder) n
            | n < 0  = error "impossible: natVal is less than 0"
            | n == 0 = Right (KIdentifier . BS.pack . reverse $ words', remainder)
            | n > 0  = case BS.uncons remainder of
                           Nothing -> Left "KIdentifier is too short"
                           Just (word, remainder') ->
                               go (word : words', remainder') (n - 1)
            | otherwise = error "Serialize KIdentifier: impossible"

instance ( KnownNat bytes ) => Binary (KIdentifier bytes) where
    put (KIdentifier bs) = putByteString bs
    get = KIdentifier <$> getByteString (fromIntegral (natVal (Proxy :: Proxy bytes)))

-- | Wrapper which provides a 'K.Serialize' instance for any type with a
--   'Binary' instance.
newtype KSerialize i = KSerialize i
    deriving (Eq, Ord, Show)

instance Binary i => K.Serialize (KSerialize i) where
    fromBS bs = case decodeOrFail (BL.fromStrict bs) of
        Left (_, _, str)         -> Left str
        Right (unconsumed, _, i) -> Right (KSerialize i, BL.toStrict unconsumed)
    toBS (KSerialize i) = BL.toStrict . encode $ i

-- | The internals of a Kademlia network discovery. It's the same as
--   'NetworkDiscovery KademliaDiscoveryErrorCode m' but also includes a
--   'KademliaInstance'.
data KademliaDiscovery (bytes :: Nat) (m :: * -> *) = KademliaDiscovery {
      kdInstance :: K.KademliaInstance (KIdentifier bytes) (KSerialize EndPointAddress)
    , kdEndPointAddresses :: TVar.TVar (M.Map (K.Node (KIdentifier bytes)) EndPointAddress)
    , kdDiscovery :: NetworkDiscovery KademliaDiscoveryErrorCode m
    }

-- | Same as 'kademliaDiscoveryExposeInternals', but a 'NetworkDiscovery'
--   is directly returned.
kademliaDiscovery
    :: forall m bytes .
       (MonadIO m, KnownNat bytes)
    => K.KademliaInstance (KIdentifier bytes) (KSerialize EndPointAddress)
    -> K.Node (KIdentifier bytes)
    -- ^ A known peer, necessary in order to join the network.
    --   If there are no other peers in the network, use this node's id.
    -> EndPointAddress
    -- ^ Local endpoint address. Will store it in the DHT.
    -> m (NetworkDiscovery KademliaDiscoveryErrorCode m)
kademliaDiscovery inst node epa = kdDiscovery <$> kademliaDiscoveryExposeInternals inst node epa

-- | Discovery peers using the Kademlia DHT. Nodes in this network will store
--   their (assumed to be TCP transport) 'EndPointAddress'es and send them
--   over the wire on request. NB there are two notions of ID here: the
--   Kademlia IDs, and the 'EndPointAddress'es which are indexed by the former.
kademliaDiscoveryExposeInternals
    :: forall m bytes .
       (MonadIO m, KnownNat bytes)
    => K.KademliaInstance (KIdentifier bytes) (KSerialize EndPointAddress)
    -> K.Node (KIdentifier bytes)
    -- ^ A known peer, necessary in order to join the network.
    --   If there are no other peers in the network, use this node's id.
    -> EndPointAddress
    -- ^ Local endpoint address. Will store it in the DHT.
    -> m (KademliaDiscovery bytes m)
kademliaDiscoveryExposeInternals kademliaInst initialPeer myAddress = do
    -- The Kademlia identifier of the local node.
    let kid = K.nodeId (K.node kademliaInst)
    -- A TVar to cache the set of known peers at the last use of 'discoverPeers'
    peersTVar :: TVar.TVar (M.Map (K.Node (KIdentifier bytes)) EndPointAddress)
        <- liftIO . TVar.newTVarIO $ M.empty
    let knownPeers = fmap (S.fromList . M.elems) . liftIO . TVar.readTVarIO $ peersTVar
    let discoverPeers = liftIO $ kademliaDiscoverPeers kademliaInst peersTVar
    -- Nothing to do on close. It's not our responsibility to close the
    -- KademliaInstance.
    -- TBD perhaps we should flip a bit here so that knownPeers and
    -- discoverPeers no longer work after 'close'?
    let close = pure ()
    -- Join the network and store the local 'EndPointAddress'.
    _ <- liftIO $ kademliaJoinAndUpdate kademliaInst peersTVar initialPeer
    () <- liftIO $ K.store kademliaInst kid (KSerialize myAddress)
    let nd = NetworkDiscovery knownPeers discoverPeers close
    pure $ KademliaDiscovery kademliaInst peersTVar nd

-- | Join a Kademlia network (using a given known node address) and update the
--   known peers cache.
kademliaJoinAndUpdate
    :: forall bytes .
       ( KnownNat bytes )
    => K.KademliaInstance (KIdentifier bytes) (KSerialize EndPointAddress)
    -> TVar.TVar (M.Map (K.Node (KIdentifier bytes)) EndPointAddress)
    -> K.Node (KIdentifier bytes)
    -> IO (Either (DiscoveryError KademliaDiscoveryErrorCode) (S.Set EndPointAddress))
kademliaJoinAndUpdate kademliaInst peersTVar initialPeer = do
    result <- K.joinNetwork kademliaInst initialPeer
    case result of
        K.NodeBanned -> pure $ Left (DiscoveryError KademliaNodeBanned "Node is banned by network")
        K.IDClash -> pure $ Left (DiscoveryError KademliaIdClash "ID clash in network")
        K.NodeDown -> pure $ Left (DiscoveryError KademliaInitialPeerDown "Initial peer is down")
        K.JoinSuccess -> do
            peerList <- K.dumpPeers kademliaInst
            -- We have the peers, but we do not have the 'EndPointAddress'es for
            -- them. We must ask the network for them.
            endPointAddresses <- fmap (M.mapMaybe id) (kademliaLookupEndPointAddresses kademliaInst M.empty peerList)
            STM.atomically $ TVar.writeTVar peersTVar endPointAddresses
            pure $ Right (S.fromList (M.elems endPointAddresses))

-- | Update the known peers cache.
--
--   FIXME: error reporting. Should perhaps give a list of all of the errors
--   which occurred.
kademliaDiscoverPeers
    :: forall bytes .
       ( KnownNat bytes )
    => K.KademliaInstance (KIdentifier bytes) (KSerialize EndPointAddress)
    -> TVar.TVar (M.Map (K.Node (KIdentifier bytes)) EndPointAddress)
    -> IO (Either (DiscoveryError KademliaDiscoveryErrorCode) (S.Set EndPointAddress))
kademliaDiscoverPeers kademliaInst peersTVar = do
    recordedPeers <- TVar.readTVarIO peersTVar
    currentPeers <- K.dumpPeers kademliaInst
    -- The idea is to always update the TVar to the set of nodes in allPeers,
    -- but only lookup the addresses for nodes which are not in the recorded
    -- set to begin with.
    currentWithAddresses <- fmap (M.mapMaybe id) (kademliaLookupEndPointAddresses kademliaInst recordedPeers currentPeers)
    STM.atomically $ TVar.writeTVar peersTVar currentWithAddresses
    let new = currentWithAddresses `M.difference` recordedPeers
    pure $ Right (S.fromList (M.elems new))

-- | Look up the 'EndPointAddress's for a set of nodes.
--   See 'kademliaLookupEndPointAddress'
kademliaLookupEndPointAddresses
    :: forall bytes .
       ( KnownNat bytes )
    => K.KademliaInstance (KIdentifier bytes) (KSerialize EndPointAddress)
    -> M.Map (K.Node (KIdentifier bytes)) EndPointAddress
    -> [K.Node (KIdentifier bytes)]
    -> IO (M.Map (K.Node (KIdentifier bytes)) (Maybe EndPointAddress))
kademliaLookupEndPointAddresses kademliaInst recordedPeers currentPeers = do
    -- TODO do this in parallel, as each one may induce a blocking lookup.
    endPointAddresses <- forM currentPeers (kademliaLookupEndPointAddress kademliaInst recordedPeers)
    let assoc :: [(K.Node (KIdentifier bytes), Maybe EndPointAddress)]
        assoc = zip currentPeers endPointAddresses
    pure $ M.fromList assoc

-- | Look up the 'EndPointAddress' for a given node. The host and port of
--   the node are known, along with its Kademlia identifier, but the
--   'EndPointAddress' cannot be inferred from these things. The DHT stores
--   that 'EndPointAddress' using the node's Kademlia identifier as key, so
--   we look that up in the table. Nodes for which the 'EndPointAddress' is
--   already known are not looked up.
kademliaLookupEndPointAddress
    :: forall bytes .
       ( KnownNat bytes )
    => K.KademliaInstance (KIdentifier bytes) (KSerialize EndPointAddress)
    -> M.Map (K.Node (KIdentifier bytes)) EndPointAddress
    -- ^ The current set of recorded peers. We don't lookup an 'EndPointAddress'
    --   for any of these, we just use the one in the map.
    -> K.Node (KIdentifier bytes)
    -> IO (Maybe EndPointAddress)
kademliaLookupEndPointAddress kademliaInst recordedPeers peer@(K.Node _ nid) =
    case M.lookup peer recordedPeers of
        Nothing -> do
            outcome <- K.lookup kademliaInst nid
            pure $ case outcome of
                Nothing                              -> Nothing
                Just (KSerialize endPointAddress, _) -> Just endPointAddress
        Just address -> pure (Just address)

data KademliaDiscoveryErrorCode
    = KademliaIdClash
    | KademliaInitialPeerDown
    | KademliaNodeBanned
    deriving (Show, Typeable, Generic)
