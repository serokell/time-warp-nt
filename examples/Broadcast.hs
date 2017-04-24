{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecursiveDo           #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE DataKinds             #-}

import           Control.Monad                        (forM, forM_, when)
import           Control.Monad.IO.Class               (liftIO)
import           Data.Binary
import qualified Data.ByteString.Char8                as B8
import qualified Data.ByteString.Lazy                 as BL
import qualified Data.Set                             as S
import           Data.Map.Strict                      (Map)
import qualified Data.Map.Strict                      as M
import           Data.String                          (fromString)
import           Data.Void                            (Void)
import           Mockable.Concurrent                  (delay, for)
import qualified Mockable.SharedAtomic                as SA
import           Mockable.Production
import           Network.Discovery.Abstract
import qualified Network.Discovery.Transport.Kademlia as K
import qualified Network.Kademlia                     as K (create, close)
import           Network.Transport.Abstract           (newEndPoint)
import           Network.Transport.Concrete           (concrete)
import qualified Network.Transport.InMemory           as InMemory
import qualified Network.Transport.TCP                as TCP
import qualified Broadcast.Abstract                   as Broadcast
import           Broadcast.Kademlia                   (kademliaBroadcast)
import           Node
import           System.Environment                   (getArgs)
import           System.Random
import           Data.Proxy                           (Proxy(Proxy))
import           Data.Digest.Pure.SHA                 (sha1, bytestringDigest, showDigest)
import           Message.Message                      (BinaryP(..))

makeId i = K.makeKIdentifierPaddedTrimmed twenty (fromIntegral 0) (BL.toStrict (bytestringDigest (sha1 (BL.fromStrict (B8.pack (show i))))))
    where
    twenty :: Proxy 20
    twenty = Proxy

-- | Make a listener node. It will listen for and repeat a "ping" message.
--   It will also update some shared state.
makeListener transport sharedState i k = do
    let port = 3000 + i
    let host = "127.0.0.1"
    let anId = makeId port
    let initialPeer =
            if i == 1
            then K.Node (K.Peer host (fromIntegral 3001)) (makeId 3001)
            else K.Node (K.Peer host (fromIntegral (3000 + (i - 1)))) (makeId (3000 + (i - 1)))
    let prng = mkStdGen port
    let hexId = showDigest (sha1 (BL.fromStrict (B8.pack (show port))))
    liftIO . putStrLn $ "Spawning listener with identifier " ++ hexId
    node transport prng BinaryP $ \node -> do
        let localAddress = nodeEndPointAddress node
        kademliaInstance <- liftIO $ K.create (fromIntegral port) anId
        discovery <- K.kademliaDiscoveryExposeInternals kademliaInstance initialPeer localAddress
        bcast <- kademliaBroadcast discovery (fromString "ping")
        pure $ NodeAction [listener discovery bcast (nodeId node)] $ \_ -> do
            k
            liftIO $ putStrLn "Closing Kademlia"
            closeDiscovery (K.kdDiscovery discovery)
            liftIO $ K.close kademliaInstance
    where
    listener discovery (_, withRepeater) nid = withRepeater $ \repeater peerid sactions (body :: Int) -> do
        --liftIO . putStrLn $ show nid ++ " : " ++ show body
        _ <- SA.modifySharedAtomic sharedState $ \map ->
            -- Int overflow is expected. All we care about is that every value
            -- in this map is eventually the same, which almost certainly
            -- means that every node heard all of the broadcasts.
            pure $ (M.alter (maybe (Just body) (Just . (+) body)) nid map, ())
        _ <- discoverPeers (K.kdDiscovery discovery)
        --peers <- knownPeers (K.kdDiscovery discovery)
        --liftIO . putStrLn $ show nid ++ " : known peers are " ++ show peers
        repeater

-- | Make a broadcaster node. It will broadcast a "ping" to the network every
--   second.
makeBroadcaster transport n = do
    let port = 3000
    let host = "127.0.0.1"
    let anId = makeId port
    let initialPeer = K.Node (K.Peer host (fromIntegral (port + 1))) (makeId (port + 1))
    let prng1 = mkStdGen port
    let prng2 = mkStdGen (port + 1)
    let hexId = showDigest (sha1 (BL.fromStrict (B8.pack (show port))))
    liftIO . putStrLn $ "Spawning broadcaster with identifier " ++ hexId
    node transport prng1 BinaryP $ \node -> do
        let localAddress = nodeEndPointAddress node
        kademliaInstance <- liftIO $ K.create (fromIntegral port) anId
        discovery <- K.kademliaDiscoveryExposeInternals kademliaInstance initialPeer localAddress
        bcast <- kademliaBroadcast discovery (fromString "ping")
        pure $ NodeAction [] $ worker discovery bcast prng2 n 
    where
    worker _ _ _ 0 _ = do
        -- When the broadcasts have stopped, we must wait for a while to let
        -- them propagate (once this worker ends, the listeners will be brought
        -- down).
        --
        -- This is a shame. TODO: some way to wait for all traffic to stop
        -- before shutting down *any* node.
        -- If there's any active handler, or any network-transport connection
        -- open, then we can't stop yet.
        liftIO . putStrLn $ "\n====\nEnd of broadcasts. Waiting 60 seconds.\n===\n"
        delay (for 60000000)
        pure ()
    worker discovery bcast@(initiator, _) prng n sactions = do
        let (m :: Int, prng') = random prng
        liftIO . putStrLn $ "Discovering"
        _ <- discoverPeers (K.kdDiscovery discovery)
        peers <- knownPeers (K.kdDiscovery discovery)
        liftIO . putStrLn $ "Broadcasting " ++ show m
        initiator m sactions
        delay (for 5000000)
        worker discovery bcast prng' (n - 1) sactions

forK :: [t] -> (t -> m () -> m ()) -> m () -> m ()
forK [] _ k = k
forK (t : ts) f k = f t (forK ts f k)

main = runProduction $ do

    [arg0, arg1] <- liftIO getArgs
    let numberOfListeners = read arg0
    let numberOfBroadcasts = read arg1

    when (numberOfListeners < 1) $ error "Give a positive number of listeners"
    when (numberOfBroadcasts < 1) $ error "Give a positive number of broadcasts"

    Right transport_ <- liftIO $ TCP.createTransport ("127.0.0.1") ("10128") TCP.defaultTCPParameters
    let transport = concrete transport_

    sharedState <- SA.newSharedAtomic M.empty

    liftIO . putStrLn $ "Spawning " ++ show numberOfListeners ++ " listener(s)"
    forK [1..numberOfListeners] (makeListener transport sharedState) $ do

        liftIO . putStrLn $ "Spawning a broadcaster"
        makeBroadcaster transport numberOfBroadcasts

        liftIO $ putStrLn "Stopping nodes"

        finalState <- SA.modifySharedAtomic sharedState $ \map -> pure (map, map)
        liftIO $ putStrLn "=== Final state is ==="
        liftIO $ print finalState

        let consistent = case M.toList finalState of
                [] -> True
                ((nodeId, value) : rest) -> all ((==) value . snd) rest

        liftIO . putStrLn $ "Consistent : " ++ show consistent
