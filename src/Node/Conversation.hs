{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}

module Node.Conversation
    ( ConversationId
    , Converse (..)
    , converseWith
    , hoistConverse
    , Conversation (..)
    , hoistConversation
    , ConversationActions (..)
    , hoistConversationActions
    ) where

import           Data.Word (Word16, Word32)
import qualified Node.Internal as LL
import           Node.Message.Class

type ConversationId = Word16

newtype Converse packingType peerData m = Converse {
      runConverse
          :: forall t .
             LL.NodeId
          -> (peerData -> Conversation packingType m t)
          -> m t
    }

converseWith
    :: Converse packingType peerData m
    -> LL.NodeId
    -> (peerData -> Conversation packingType m t)
    -> m t
converseWith = runConverse

hoistConverse
    :: (forall a . m a -> n a)
    -> (forall a . n a -> m a)
    -> Converse packingType peerData m 
    -> Converse packingType peerData n
hoistConverse nat rnat (Converse k) = Converse $ \nodeId l ->
    let l' = \peerData -> hoistConversation rnat nat (l peerData)
    in  nat (k nodeId l')

-- | Use ConversationActions on some Serializable send and receive types.
data Conversation packingType m t where
    Conversation
        :: ConversationId
        -> (ConversationActions packingType m -> m t)
        -> Conversation packingType m t

hoistConversation
    :: (forall a . m a -> n a)
    -> (forall a . n a -> m a)
    -> Conversation packingType m t
    -> Conversation packingType n t
hoistConversation nat rnat (Conversation cid k) = Conversation cid k'
  where
    k' cactions = nat (k (hoistConversationActions rnat cactions))

data ConversationActions packingType m = ConversationActions {
       -- | Send a message within the context of this conversation
       send :: forall snd . Serializable packingType snd => snd -> m ()

       -- | Receive a message within the context of this conversation.
       --   'Nothing' means end of input (peer ended conversation).
       --   The 'Word32' parameter is a limit on how many bytes will be read
       --   in by this use of 'recv'. If the limit is exceeded, the
       --   'LimitExceeded' exception is thrown.
     , recv :: forall rcv . Serializable packingType rcv => Word32 -> m (Maybe rcv)
     }

hoistConversationActions
    :: forall packingType n m .
       (forall a. n a -> m a)
    -> ConversationActions packingType n
    -> ConversationActions packingType m
hoistConversationActions nat ConversationActions {..} =
  ConversationActions send' recv'
      where
        send' :: forall snd . Serializable packingType snd => snd -> m ()
        send' = nat . send
        recv' :: forall rcv . Serializable packingType rcv => Word32 -> m (Maybe rcv)
        recv' = nat . recv
