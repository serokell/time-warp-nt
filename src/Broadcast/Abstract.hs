module Broadcast.Abstract (

      Broadcast

    , Initiator
    , Repeater
    , WithRepeater

    ) where

import Node

-- | A broadcast constructs what's necessary to initiate and repeat messages
--   for a given name.
type Broadcast packing peerData body m =
    m (Initiator packing peerData body m, WithRepeater packing peerData body m)

-- | Initiate a broadcast of a given payload.
type Initiator packing peerData body m = body -> SendActions packing peerData m -> m ()

-- | Repeat the broadcast of a given payload.
type Repeater m = m ()

type WithRepeater packing peerData body m =
     (Repeater m -> NodeId -> SendActions packing peerData m -> body -> m ())
  -> Listener packing peerData m
