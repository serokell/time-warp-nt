# Static peer data

## Inbound connections

Currently we guarantee the peer data to be present for incoming connections:
listeners and locally-initiated bidirectional connections. That's somewhat
clear from the types:

```Haskell
peerData :: ConversationActions peerData body rcv m -> m peerData

listenerActionOneMsg
    :: peerData
    -> NodeId
    -> SendActions packing peerData m
    -> msg
    -> m ()

-- Note the duplicate: peerData is here _and_ in the ConversationActions.
-- This is fixed in one of my branches.
listenerActionConversation
    :: peerData
    -> NodeId
    -> ConversationActions peerData snd rcv m
    -> m ()
```

The branch mentioned is [here](https://github.com/serokell/time-warp-nt/pull/18).

time-warp-nt ensures that the peer data is not transmitted unnecessarily. *The
peer data of a given peer is held for as long as there is at least one
connection to or from it*. This makes sense, because the peer data is assumed
to be constant for the lifetime of a node. If it is to change, the node must
go down, and therefore all of its connections to any other node must be severed.

## Outbound unidirectional connections

It's come to our attention that the peer data is necessary even for outbound
unidirectional connections. In practice (CSL) the peer data is version info
(`VerInfo`) and it shall be used by a connecting node to determine exactly
how to talk to its peer. Perhaps the peer is running an earlier version (the
`VerInfo` is intended to be consistent or at least compatible between versions)
in which case the contacting peer should speak the language of the older
version.

And so the type of `sendTo` is not what we need:

```Haskell
sendTo :: NodeId -> msg -> m ()
```

What we're after is something like this:

```Haskell
sendTo :: NodeId -> (peerData -> m msg) -> m ()
```

Here, the `msg` can depend upon the peer data at peer given by the `NodeId`,
and of course the peer data itself depends upon the `NodeId`.

## Sessions

Both `sendTo` and `withConnectionTo` has the peer data of the target peer.
We may want to introduce explicit *sessions*, like this:

```Haskell
withPeer :: NodeId -> (Session packingType peerData m -> m t) -> m t

data Session packingType peerData m = Session {
      peerData :: peerData
    , sendTo
          :: forall msg .
             ( Packable packingType msg, Message msg )
          => msg
          -> m ()
    , withConnection
          :: forall snd rcv t .
             ( Packable packingType snd, Message snd, Unpackable packingType rcv )
          => (ConversationActions snd rcv m -> m t)
          -> m t
    }

data ConversationActions snd rcv m = ConversationActions {
      send :: snd -> m ()
    , recv :: m (Maybe rcv)
    }
```

If we already have the peer data (there is some other live session) then
`withPeer` returns right away (it doesn't even have to make a new lightweight
connection). Otherwise, it will wait until the peer has delivered their peer
data, and then return with the `Session` value, allowing the caller to engage
the peer.

In any case, every outbound connection, whether unidirectional or bidirectional,
*may* require the peer to send back its peer data before the initiating node
can continue. If we offer explicit sessions as described above, a node has a
certain degree of control over how often this can happen: so long as the
action given to `withPeer` continues, the peer data will be retained and the
socket to that peer held open. This could be a very good thing, if it's often
the case that a node *anticipates* that it will be making many transmissions
to a given peer.

### Implemetation: a session connection?

We need to guarantee that, so long as the term given to `withPeer` is ongoing,
there is always at least one lightweight connection to that peer. So, for
example:

```Haskell
withPeer peer $ \session -> do
    !msg <- return (expensivePureComputation (peerData session))
    sendTo session msg
```

Under normal conditions (no network problems etc.) a heavyweight connection
to `peer` must be up even while the `expensivePureComputation` is going. Since
`sendTo` happens only after that, it's clear that `withPeer` needs to
keep some lightweight connection up until its argument returns. It needs
a lightweight connection in order to exchange peer data, so we may as well
just keep that connection up.

There will be some symmetry in the system from the application level's point
of view: *as far as the application can tell, `A` has a lightweight connection
to `B` if and only if `B` has a lightweight connection to `A`; `A` has the peer
data of `B` if and only if `B` has the peer data of `A`.*

This is all to say: *a session between `A` and `B` is a pair of lightweight
connections, one in each direction, each of which sends its node's peer data
and then goes quiet. When either connection closes, the session closes.*

No control code is necessary here. The first lightweight connection from a
given peer is assumed to be the session connection.

What to do if the session connection is closed before some other connection?
That's a protocol error.

### Closing sessions

At the application level, only the connecting node knows about a session; the
remote peer still works with individual listeners (although the remote peer may
have its own session(s) with the connecting peer).

As far as I can tell there is no cleanup that must be done when a session is
closed apart from some shared state update (we will have to count the number
of sessions, so we know whether a new session must send peer data).

If there is a network exception to the remote peer, then there must be a
session with that peer (else there would be no lightweight connections), so
the dispatcher can find every connection in that session and close the
corresponding input channels (so handlers won't block waiting for data). Any
call to `send` would throw an exception, and we can rig it so that `recv`
does as well (by putting an exception into the channel). We could also throw
an asynchronous exception to the handler, but this is probably overkill: it
could be that the handler has already completed use of its connections and can
finish normally.

### Do we need `sendTo`?

With this design there are two similar notions: the session, which provides
peer data, and the conversation, which provides sending and receiving
capabilities under one particular message name. The programmer makes a *session*
with a peer, which scopes 0 or more possibly concurrent *connections* to that
peer, and that's all. A unidirectional `sendTo` fits this model: it's just a
connection in which the receive type is `Void`.

```Haskell
withPeer :: NodeId -> (Session packingType peerData m -> m t) -> m t

data Session packingType peerData m = Session {
      peerData :: peerData
    , withConnection
          :: forall snd rcv t .
             ( Packable packingType snd, Message snd, Unpackable packingType rcv )
          => (ConversationActions snd rcv m -> m t)
          -> m t
    }

data ConversationActions snd rcv m = ConversationActions {
      send :: snd -> m ()
    , recv :: m (Maybe rcv)
    }

sendTo 
    :: forall msg m .
       ( Packable packingType msg, Message msg )
    => Session packingType peerData m
    -> msg
    -> m ()
sendTo session msg = withConnection session $
    \(cactions :: ConversationActions msg Void m) -> send cactions msg
```
