# Diffusion / application interface

A good first step in Shelley networking implementation is to carve out the
interface between application and diffusion, so that we can do our work
independently (besides the architectural advantages).

In summary: all "conversation" and relaying is done by the diffusion layer
only. This way application latency does not inflate network latency. Input to
the application layer will come from the diffusion layer rather than from a
set of network listeners. Output to the network will go via the diffusion
layer, and may not offer any feedback on success or failure. 

A rough sketch of the interface:

```Haskell
-- Direction: application => diffusion

-- Synchronously ask the diffusion layer for the blocks from a tip to a set
-- of checkpoints. Inspired by the current block headers request that's made
-- during recovery mode.
getBlocks :: HeaderHash -> [HeaderHash] -> IO [Block]
-- Special case of getting one block. May be faster to implement not in terms
-- of getBlocks?
getBlock :: HeaderHash -> IO (Maybe Block)

-- Ask for the tip-of-chain for peers.
-- TBD whether this will be needed.
-- Diffusion layer decides when it returns (must have a timeout) and of course
-- which peers to ask.
--
-- A 'RawBlockHeader' is given, i.e. it's decoded from the wire but not
-- validated. Application layer can validate it as needed.
getTips :: IO [RawBlockHeader]

-- Offer a block for diffusion.
-- Is it OK to return right away? Or should the diffusion layer respond with
-- some indication of whether the block was actually sent to some threshold of
-- peers?
announceBlock :: Block -> IO ()

-- Similar for other data that can be broadcast
-- (transactions, ssc, update, etc.)
```

```Haskell
-- Direction: diffusion => application

-- Give various data to the application layer asynchronously (drop it in some
-- queue).
block :: Block -> IO ()
blockHeader :: BlockHeader -> IO ()
transaction :: Tx -> IO ()
...

-- Check whether a block header could possibly be for a legitimate block
-- (signed by slot leader).
isValidBlockHeader :: BlockHeader -> IO Bool

-- Quick sanity check for a transaction, to determine whether we should forward
-- it.
isValidTransaction :: Tx -> IO Bool

-- Application is in control of databases, but the diffusion layer may want to
-- use it, for instance if a peer asks for a block that's not in its cache.
getBlockFromDB :: HeaderHash -> IO Block

-- TBD whether we'll need this.
-- If the application layer ever needs to know the tips of peers, then we will
-- indeed need it.
getTipFromDB :: IO RawBlockHeader
```

## Queueing / buffering between these layers

It's expected that the two layers will operate at different rates / have
different throughput. The diffusion layer will probably be able to process more
blocks per second than the application can (we hope). It's important not to
impose too much synchronization between the two. So we'll want some kind of
queueing mechanism for passing data up from diffusion to application.
This way `block`, `blockHeader`, `transaction`, etc. can be non-blocking
always. We'll probably want to prioritize certain data (a block for the
current slot) and have it jump the queue.

For a treatment like this, we'd have to rearchitecht cardano-sl so that it
doesn't spawn arbitrarily-many threads (it clears the queue from the diffusion
layer at a rate proportional to actual productivity).

We may want queueing in the other direction as well, from application to
diffusion, since it's plausible that the diffusion layer could get backed up
too.

## [CSL-1817]

Must provide an interface satisfying the needs of [CSL-1817], so that the
application layer can make use of the (presently hypothetical) connectivity
status.
Ideally we can satisfy [CSL-1817] very soon, by deciding on an interface,
backing it with existing infrastructure, and improving it later on.

We probably need to know more information than just the known peers.
  - To whom we actually have a connection.
  - The quality of and activity on these connections.
    - Network-relevant (in terms of bytes) but maybe also application-relevant
      (in terms of blocks, transactions, etc.).
  - Possible to give bittorrent style metrics: connected to n of m peers,
    where the m comes from discovery (Kademlia).

What should the `diffusion => application` interface look like in order to
accomodate this? Give a `TVar` containing all the relevant info? Have a
side-channel for metadata like these?

## Implementation plan

We'll swap out all of the time-warp listeners for functions which take the
relevant input from the diffusion layer (block, transaction, etc.) and move
the listeners themselves down to the diffusion layer without the application
logic parts.

There will be a single thread in the application layer which clears the
input queue from the diffusion layer and forks a thread with a handler for
each.

```Haskell
data InputFromDiffusionLayer =
    BlockHeader HeaderHash
  | Transaction Tx
  | MPC RelevantMPCData
  | Update RelevantUpdateData
  | ...

type Application m = InputFromDiffusionLayer -> m ()

type InputQueue = TBQueue InputFromDiffusionLayer

withDiffusionLayerInput :: Application m -> InputQueue -> m x
withDiffusionLayerInput go q = do
  inp <- readTBQueue q
  _ <- async (go inp)
  withDiffusionLayerInput go q
```

### Inv/Req/Data

Much of the network interaction is handled by the Inv/Req/Data relay system.
Pulling this down into the diffusion layer should be straightforward. It will
use synchronous `diffusion => application` API functions to get the data in
response to requests, and the asynchronous API in response to data from peers
(the data will be passed on through some queue).

### Block, block headers, and recovery mode

Block and block header communication and relaying does not use the Inv/Req/Data
system.

#### Block header announcement and block serving

To announce a block header, simply pass it to the diffusion layer. The
implementation of serving blocks and block headers will be moved to the
diffusion layer, and supported by the synchronous API to get blocks and block
headers (from the database, which is owned by the application layer). In
future we'll put in a diffusion layer cache, but that's not part of this
initial work.

#### Block retrieval

Block retrieval has more moving parts than header announcement. There's a
retrieval queue which came to be because block headers are sent without
their bodies, and the recipient is not offered a chance to ask for the body
within the same conversation. So the headers are thrown into a queue and some
thread will eventually request the body (unless it considered useless by the
time it comes out of the queue).

We can leave this in place for the initial work, and discuss a better solution
later. The application layer handler for block headers will remain largely the
same, except that it will take input from the diffusion layer and drop it into
the application layer queue as it does now. The block retrieval worker will
pick it up and do the relevant logic, unless...

#### Recovery mode

Sometimes the block retrieval worker will trigger recovery mode, in case it
finds a header which doesn't immediately continue the tip. This recovery
process uses time-warp conversations for control flow: it will get the headers
and blocks needed to go from current tip to new tip, and then return to the
block retrieval queue clearing loop, possibly ending recovery mode.

We can keep this as is (equally bad, not worse) by using the synchronous
`getBlocks` function and letting the diffusion layer take care of finding them.
