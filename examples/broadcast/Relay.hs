{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad.IO.Class (liftIO)
import Control.Monad (forM, forM_, when)
import Control.Exception (SomeException)
import Data.Binary
import Data.Monoid
import Data.Void
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map (Map)
import qualified Data.Map as Map
import Data.List ((!!))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Time.Units (Microsecond)
import Node
import Node.Message.Class
import Node.Message.Decoder
import Node.Message.Binary
import Mockable.SharedExclusive
import Mockable.SharedAtomic
import Mockable.Concurrent
import Mockable.CurrentTime
import Mockable.Exception
import Mockable.Production
import Network.Broadcast.Relay.Class
import Network.Broadcast.Relay.Types
import Network.Broadcast.Relay.Logic
import Network.Transport.InMemory
import Network.Transport.Abstract
import Network.Transport.Concrete
import System.Random

data RelayedMessage = RelayedMessage
    { rmSendTime :: !Microsecond
    , rmReceived :: !(Map NodeId (NonEmpty ReceivedMessage))
    }
    deriving (Show)

data ReceivedMessage = ReceivedMessage
    { rmReceivedTime :: !Microsecond
    , rmReceivedFrom :: !NodeId
    }
    deriving (Show)

type Key = Int
type Value = Key

type GlobalState = Map Key RelayedMessage
type LocalState = Set Key

showGlobalState :: GlobalState -> String
showGlobalState = show

initialGlobalState :: GlobalState
initialGlobalState = Map.empty

globalStateSend :: Microsecond -> Int -> GlobalState -> GlobalState
globalStateSend time key gst = Map.insert key relayed gst
  where
    relayed = RelayedMessage
        { rmSendTime = time
        , rmReceived = Map.empty
        }

globalStateReceive :: NodeId -> NodeId -> Microsecond -> Int -> GlobalState -> GlobalState
globalStateReceive receiver sender time key gst = case Map.lookup key gst of
    Nothing -> error "Received key which was never relayed"
    Just rm ->
        let receivedMessage = ReceivedMessage
                { rmReceivedTime = time
                , rmReceivedFrom = sender
                }
            alteration Nothing = Just $ receivedMessage NonEmpty.:| []
            alteration (Just ne) = Just $ receivedMessage NonEmpty.<| ne
            rmReceived' = Map.alter alteration receiver (rmReceived rm)
        in  Map.insert key (rm { rmReceived = rmReceived' }) gst

instance Binary (ReqMsg Key)

instance Binary (InvMsg Key)

instance Binary (DataMsg Value)

instance Message (InvOrData Key Value) where
  messageName _ = "InvOrData"
  formatMessage = undefined

instance Message (ReqMsg Key) where
  messageName _ = "ReqMsg"
  formatMessage = undefined

instance Message (DataMsg Value) where
  messageName _ = "DataMsg"
  formatMessage = undefined

-- | 
makeNode
    :: NodeId
    -> SharedAtomicT Production GlobalState
    -> EndPoint Production
    -> StdGen
    -> (Maybe NodeId -> Production (Set NodeId))
    -> Production ()
makeNode myNodeId globalState endPoint prng getNeighbours = do

    -- Local state: records all 'Key's seen so far.
    localState <- newSharedAtomic Set.empty

    (propagate, relay) <- simpleRelayer getNeighbours
    let relayParams :: InvReqDataParams Key Value Production
        relayParams = InvReqDataParams
            { -- The contents is the key (in this example, the Inv is
              -- useless since it contains all the data).
              contentsToKey = \k -> pure k

              -- If we don't have the key, then we'll request the value.
            , handleInv = \peer key -> withSharedAtomic localState $ \s -> do
                  let b = not . Set.member key $ s
                  when (not b) $ liftIO . putStrLn $ concat
                      [ show myNodeId
                      , " ignoring inv from "
                      , show peer
                      ]
                  pure b

              -- When somebody requests a key, we'll give them our value (if
              -- it's in the set).
            , handleReq = \peer key -> withSharedAtomic localState $ \s -> pure $
                  if Set.member key s
                  then Just key
                  else Nothing

              -- Put a value into the local state Set, update the global state
              -- to show that this node got it and from whom it came, then
              -- return True iff it should be propagated (if it's new).
            , handleData = \peer key -> modifySharedAtomic localState $ \s ->
                  if Set.member key s
                  then do liftIO . putStrLn $ concat
                              [ show myNodeId
                              , " got data I already have from "
                              , show peer
                              ]
                          pure (s, False)
                  else do let set' = Set.insert key s
                          liftIO . putStrLn $ concat
                              [ show myNodeId
                              , " got data I don't have from "
                              , show peer
                              ]
                          receivedAt <- currentTime
                          modifySharedAtomic globalState $ \gst ->
                              pure (globalStateReceive myNodeId peer receivedAt key gst, ())
                          pure $ (set', True)
            }
        relayDescription :: Relay BinaryP Production
        relayDescription = InvReqData propagate relayParams
        rlisteners = relayListeners [relayDescription]

    node
        (manualNodeEndPoint endPoint)
        (const noReceiveDelay)
        (const noReceiveDelay)
        prng
        BinaryP
        ()
        defaultNodeEnvironment $ \theNode -> NodeAction (const rlisteners) $ \sactions -> do
            liftIO $ putStrLn (show myNodeId ++ " up and running " ++ show (nodeId theNode))
            relay sactions
      `Mockable.Exception.finally`
      (liftIO $ putStrLn (show myNodeId ++ " stopping"))

main = runProduction $ do

    -- Opting for the in-memory transport, because the TCP variant that we use
    -- still has that shameful emergency hack which defaults every peer
    -- claiming 127.0.0.1 or 0.0.0.0 as its host to a random address (assumes
    -- it's unaddressable) to prevent self-inflicted denial-of-service.
    memoryTransport <- liftIO $ createTransport
    let transport = concrete memoryTransport

    globalState <- newSharedAtomic initialGlobalState
    let nRelayers = 10

    rec relayers <- forM [1..nRelayers] $ \n -> do
            Right ep <- newEndPoint transport
            let nid = NodeId (address ep)
                prng = mkStdGen n
            nodeThread <- async $ makeNode nid globalState ep prng getNeighbours
            return (nid, (nodeThread, ep))
        let allNodes :: [NodeId]
            allNodes = fmap fst relayers
            getNeighbours :: Maybe NodeId -> Production (Set NodeId)
            getNeighbours Nothing = pure $ Set.fromList allNodes
            getNeighbours (Just n) = pure $ Set.fromList allNodes Set.\\ Set.singleton n

    -- The relay initiator.
    Right initiatorEndPoint <- newEndPoint transport
    -- We want to be able to choose the initial targets of the broadcast.
    -- It's a little awkward with the current interface, which doesn't allow
    -- the initiator to explicitly state them. Instead, they'll be computed in
    -- the same way each time, but with side-effects, so we'll use a mutable
    -- cell.
    broadcastTargets <- newSharedAtomic Set.empty
    let getInitialTargets _ = readSharedAtomic broadcastTargets
    (initiate :: PropagationMsg BinaryP -> Production (), relay)
        <- simpleRelayer getInitialTargets
    node
        (manualNodeEndPoint initiatorEndPoint)
        (const noReceiveDelay)
        (const noReceiveDelay)
        (mkStdGen 0)
        BinaryP
        ()
        defaultNodeEnvironment $ \theNode -> NodeAction (const []) $ \sactions ->
            withAsync (relay sactions) $ \_ -> interactiveRelay globalState broadcastTargets allNodes initiate
                `catch` (\(e :: SomeException) -> liftIO . putStrLn $ show e)
                {-
                liftIO $ putStrLn "Initiator started"
                liftIO $ getChar
                now <- currentTime
                modifySharedAtomic globalState $ \gst ->
                    pure (globalStateSend now 1 (globalStateSend now 0 gst), ())
                initiate $ InvReqDataPM Nothing (0 :: Int) (0 :: Int)
                initiate $ InvReqDataPM Nothing (1 :: Int) (1 :: Int)
                liftIO $ getChar
                liftIO $ putStrLn "Initiator stopped"
                --interactiveRelay
                -}

    liftIO $ putStrLn "Killing relayers"
    forM_ (fmap snd relayers) $ \(thread, ep) -> cancel thread
    closeTransport transport

    liftIO $ putStrLn "All done. Global state is: "
    withSharedAtomic globalState $ liftIO . print

    return ()

data Command = Quit | Send [Int]
  deriving (Read, Show)

interactiveRelay
    :: SharedAtomicT Production GlobalState
    -> SharedAtomicT Production (Set NodeId)
    -> [NodeId]
    -> (PropagationMsg BinaryP -> Production ())
    -> Production ()
interactiveRelay globalState targets allPeers initiate = do
    interactiveRelay_ 0
  where
    interactiveRelay_ :: Int -> Production ()
    interactiveRelay_ current = do
        x <- liftIO $ fmap read getLine
        case x of
            Quit -> pure ()
            Send ids -> do
                modifySharedAtomic targets $ \ts ->
                    pure (Set.fromList (select ids), ())
                now <- currentTime
                modifySharedAtomic globalState $ \gst ->
                    pure (globalStateSend now 1 (globalStateSend now 0 gst), ())
                initiate $ InvReqDataPM Nothing current current
                interactiveRelay_ (current + 1)

    select :: [Int] -> [NodeId]
    select [] = []
    select (i : is) = (allPeers !! (i - 1)) : select is
