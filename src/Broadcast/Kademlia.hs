{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

module Broadcast.Kademlia (

      kademliaBroadcast

    ) where

import           GHC.Generics (Generic)
import           GHC.TypeLits (KnownNat)
import           Control.Monad (forM)
import           Control.Applicative ((<|>))
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.STM.TVar as STM
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Network.Discovery.Abstract
import           Network.Discovery.Transport.Kademlia
import qualified Network.Kademlia as K
import qualified Network.Kademlia.Instance as KI
import qualified Network.Kademlia.Tree as KT
import           Network.Kademlia.Types (toByteStruct, distance, ByteStruct, nodeId, xor)
import           Broadcast.Abstract
import           Data.Binary
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import qualified Node as N
import           Mockable.Class (Mockable)
import           Mockable.Concurrent (forConcurrently, Concurrently)
import           Message.Message (Serializable, BinaryP)

data WithKademliaIdentifier bytes body = WithKademliaIdentifier {
      wkiIdentifier :: KIdentifier bytes
    , wkiBody :: body
    }

deriving instance ( Show body ) => Show (WithKademliaIdentifier bytes body)

instance ( KnownNat bytes, Binary body ) => Binary (WithKademliaIdentifier bytes body) where
    put wki = do
        put (wkiIdentifier wki)
        put (wkiBody wki)
    get = WithKademliaIdentifier <$> get <*> get

kademliaBroadcast
    :: forall bytes body m .
       ( KnownNat bytes, Binary body, MonadIO m, Mockable Concurrently m )
    => KademliaDiscovery bytes m
    -> Broadcast BinaryP body m
kademliaBroadcast kd messageName = do
    initiator <- pure $ kademliaInitiator kd messageName
    withRepeater <- pure $ kademliaWithRepeater kd messageName
    pure (initiator, withRepeater)

kademliaInitiator
    :: forall bytes body m .
       ( KnownNat bytes, Binary body, MonadIO m, Mockable Concurrently m )
    => KademliaDiscovery bytes m
    -> N.MessageName
    -> Initiator BinaryP body m
kademliaInitiator kd messageName body sactions = do
    let payload = WithKademliaIdentifier myKId body
    kademliaTree <- liftIO . STM.atomically . STM.readTVar . KI.sTree . KI.state . kdInstance $ kd
    knownAddresses <- liftIO . STM.atomically . STM.readTVar . kdEndPointAddresses $ kd
    -- We get the targets from the KademliaInstance, but we don't necessarily
    -- have their EndPointAddress's! Those are kept by the Discovery layer.
    -- It's possible that we're aware of a node (it's in a k-bucket on the
    -- kademlia instance) but we're not (yet) aware of its EndPointAddress.
    --
    -- KT.toView doesn't give us quite what we want. Each element of the list
    -- does not necessarily correspond to a distinct subtree, i.e. there could
    -- be a list in 'targets' which contains more than one node that should be
    -- contacted.
    -- The size of these lists is bounded (referred to as k in the literature I
    -- think, they're k-buckets) so...
    --
    -- TODO this is not quite right. Must choose precisely one node with
    -- a given MostSignificant 1 bit.
    --let buckets = KT.toView kademliaTree >>= organizeBucket . eliminateId myKId
    let buckets = organizeBucket myKId . eliminateId myKId . KT.toList $ kademliaTree
    --liftIO . putStrLn $ "Initial broadcast buckets are " ++ show buckets
    _ <- forConcurrently buckets $ \knodes -> case firstKnownAddress knownAddresses knodes of
        -- TODO we know a node but not yet its address. This isn't an
        -- error and will probably happen once in a while. Log it?
        Nothing -> do
            --liftIO . putStrLn $ "Missing addresses for " ++ show knodes
            pure ()
        Just addr -> do
            --liftIO . putStrLn $ "Initiating broadcast to " ++ show addr
            N.sendTo sactions (N.NodeId addr) messageName payload
    pure ()
    where
    myKId = K.nodeIdentifier (kdInstance kd)

kademliaWithRepeater
    :: forall bytes body m .
       ( Binary body, KnownNat bytes, MonadIO m, Mockable Concurrently m )
    => KademliaDiscovery bytes m
    -> N.MessageName
    -> WithRepeater BinaryP body m
kademliaWithRepeater kd messageName f = N.Listener messageName $ N.ListenerActionOneMsg $ \nodeId sactions (wki :: WithKademliaIdentifier bytes body) -> do
    let senderKId = wkiIdentifier wki
    let body = wkiBody wki
    let repeater = do
            let payload = WithKademliaIdentifier myKId body
            kademliaTree <- liftIO . STM.atomically . STM.readTVar . KI.sTree . KI.state . kdInstance $ kd
            knownAddresses <- liftIO . STM.atomically . STM.readTVar . kdEndPointAddresses $ kd
            let buckets = bucketsCloserTo myKId senderKId kademliaTree
            --liftIO . putStrLn $ "Repeat broadcast buckets are " ++ show buckets
            --liftIO . putStrLn $ "My id is " ++ show (toByteStruct myKId)
            --liftIO . putStrLn $ "His id is " ++ show (toByteStruct senderKId)
            _ <- forConcurrently buckets $ \knodes -> case firstKnownAddress knownAddresses knodes of
                Nothing -> pure ()
                Just addr -> N.sendTo sactions (N.NodeId addr) messageName payload
            pure ()
    f repeater nodeId sactions body
    where
    myKId = K.nodeIdentifier (kdInstance kd)

firstKnownAddress :: Ord k => M.Map k v -> [k] -> Maybe v
firstKnownAddress map lst = case lst of
    [] -> Nothing
    (x : xs) -> M.lookup x map <|> firstKnownAddress map xs

eliminateId :: Eq k => k -> [Node k] -> [Node k]
eliminateId k = filter ((/=) k . nodeId)

bucketsCloserTo
    :: forall bytes .
       ( KnownNat bytes )
    => KIdentifier bytes
    -> KIdentifier bytes
    -> KT.NodeTree (KIdentifier bytes)
    -> [[K.Node (KIdentifier bytes)]]
bucketsCloserTo here there tree@(KT.NodeTree _ _) =
    buckets [trimBucket' bshere bsthere (KT.toList tree)]
    --subtree bshere bsthere tree
    where
    -- Follow the NodeTree until a differing bit is found and give the tree
    -- on the "here" side of the tree. That's a subtree where every element is
    -- closer to "here" than to "there".
    subtree
        :: [Bool]
        -> [Bool]
        -> KT.NodeTreeElem (KIdentifier bytes)
        -> [[Node (KIdentifier bytes)]]
    -- Same bits: recurse.
    subtree (True:bshere') (True:bsthere') (KT.Split _ right) = subtree bshere' bsthere' right
    subtree (False:bshere') (False:bsthere') (KT.Split left _) = subtree bshere' bsthere' left
    -- Different bits: take the one on the side of 'bshere' (right for 1 bit,
    -- left for 0 bit).
    subtree (True:bshere') (False:bsthere') (KT.Split _ right)  = buckets (KT.toView (KT.NodeTree bshere' right))
    subtree (False:bshere') (True:bsthere') (KT.Split left _) = buckets (KT.toView (KT.NodeTree bshere' left))
    -- Reached a bucket: we're not quite ready to return it. First, some
    -- nodes in there must be eliminated depending upon 'bshere' and 'bsthere'.
    --
    subtree bshere' bsthere' (KT.Bucket ns) =
        let trimmed :: [Node (KIdentifier bytes)]
            trimmed = trimBucket bshere' bsthere' (fmap fst . fst $ ns)
        in  buckets [trimmed]

    -- Organize buckets according to most-significant 1 bit and eliminate any
    -- node with the 'here' identifier.
    buckets
        :: [[Node (KIdentifier bytes)]]
        -> [[Node (KIdentifier bytes)]]
    buckets = flip (>>=) (organizeBucket here . eliminateId here . eliminateId there)

    -- Eliminate nodes which are closer to the second [Bool] than to the
    -- first [Bool].
    trimBucket
        :: [Bool]
        -> [Bool]
        -> [Node (KIdentifier bytes)]
        -> [Node (KIdentifier bytes)]
    trimBucket bshere bsthere = filter $ \node ->
        let fromHere = xor (toByteStruct (nodeId node)) bshere
            toThere = xor (toByteStruct (nodeId node)) bsthere
        in  case fromHere `compare` toThere of
                EQ -> False
                LT -> True
                GT -> False

    trimBucket'
        :: [Bool]
        -> [Bool]
        -> [Node (KIdentifier bytes)]
        -> [Node (KIdentifier bytes)]
    trimBucket' here there = filter $ \node -> go here there (toByteStruct (nodeId node))
      where
      go here there bs = case (here, there, bs) of
          (True:here', True:there', True:bs') -> go here' there' bs'
          (True:here', True:there', False:bs') -> False
          (False:here', False:there', False:bs') -> go here' there' bs'
          (False:here', False:there', True:bs') -> False
          (True:here', False:there', False:bs') -> False
          (True:here', False:there', True:bs') -> True
          (False:here', True:there', False:bs') -> True
          (False:here', True:there', True:bs') -> False
          -- Both are equal.
          ([], [], []) -> False

    bshere :: [Bool]
    bshere = toByteStruct here
    bsthere :: [Bool]
    bsthere = toByteStruct there


-- This is not working right because the NodeTree isn't necessarily very tall.
-- We need a way to take a bucket (a [Node i]) and give it the tree structure.
--
-- The most straightforward way I can see is to use the bit structure, though
-- that's in practice going to be 160 elements and may be too slow.
--
-- Broadcast: for each thing in the bucket, we want to take its distance from
-- the broadcaster, and then insert it into a map keyed on its most significant
-- 1 bit. Then we just take the elements of this map. 

newtype MostSignificant = MostSignificant {
      getMostSignificant :: ByteStruct
    }

instance Eq MostSignificant where
    MostSignificant left == MostSignificant right = msbEq left right

instance Ord MostSignificant where
    MostSignificant left `compare` MostSignificant right = msbCompare left right

msbEq :: ByteStruct -> ByteStruct -> Bool
msbEq (True:_) (True:_) = True
msbEq (False:left) (False:right) = msbEq left right
msbEq _ _ = False

msbCompare :: ByteStruct -> ByteStruct -> Ordering
msbCompare (True:_) (True:_) = EQ
msbCompare (False:left) (False:right) = msbCompare left right
msbCompare (False:_) (True:_) = LT
msbCompare (True:_) (False:_) = GT

-- | Organize a bucket into a list of buckets, where each list consists of
--   nodes which have the same most-significant 1 bit.
organizeBucket
    :: forall bytes .
       ( KnownNat bytes )
    => KIdentifier bytes
    -> [Node (KIdentifier bytes)]
    -> [[Node (KIdentifier bytes)]]
organizeBucket kId = M.elems . msbMap
    where
    msbMap :: [Node (KIdentifier bytes)] -> M.Map MostSignificant [Node (KIdentifier bytes)]
    -- msbMap = flip foldr M.empty $ \node ->
    --     M.alter (maybe (Just [node]) (Just . (:) node)) (MostSignificant (toByteStruct (nodeId node)))
    msbMap = flip foldr M.empty $ \node ->
        M.alter (maybe (Just [node]) (Just . (:) node)) (MostSignificant (nodeId node `distance` kId))

    --referenceBits = toByteStruct kId

{-
-- The n'th element of the resulting list consists only of nodes whose identifier
-- bit xor'd with the reference bit has most significant 1 bit at the n'th
-- spot.
organizeBucket'
    :: forall bytes .
       ( KnownNat bytes )
    => KIdentifier bytes
    -> [Node (KIdentifier bytes)]
    -> [[Node (KIdentifier bytes)]]
organizeBucket' kId nodes = go referenceBits nodes []
    where
    go _ [] acc = acc
    go [] _ acc = error "organizeBucket' this case makes no sense"
    go (bit:bits) nodes acc = 
    referenceBits = toByteStruct kId
    -}
