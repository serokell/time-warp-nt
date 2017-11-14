# Communication patterns (pub/sub, request/response)

## Overview

Instead of initating and forwarding broadcasts (choosing the 'out' edges), nodes
will publish and subscribe (choose the 'in' edges). 

A subscription will be organized into topics (blocks, transactions, MPC, etc.).

Pub/sub will be part of the diffusion layer. It will use the peer roster
(discovery with QoS estimation and core DIF feature) to choose which peers to
subscribe to. Publishers do not necessary have subscribers in their peer roster.
That's to say, a subscriber isn't necessarily judged to be a candidate for
subscribing to. The judgement "I should subscribe to this peer" will not be
symmetric.

The subscription mechanism must be reactive: it must be possible to subscribe
in response to a subscription. The motivating application is a relay program
which subscribes to a topic only if at least one other node has subscribed
to it for that same topic. Call it lazy subscription.
This shouldn't be a problem, because the same system which observes new
subscriptions is responsible for making subscriptions to others.

A request/response pattern must also be supported, so that a node can actively
get data such as blocks or block headers that it knows it needs.

### Interface with application layer

It's enlightening to look at the proposed interface presented by the diffusion
layer (where pub/sub lives) and the application layer (see this
[document](./Interface.md)). It's transparent to pub/sub; the application
layer won't know about it. Functions like `announceBlock` which diffuse data
will induce a publish of that thing. Every subscriber for the block topic will
be delivered the block.

Functions like `getBlocks` which bring data up from the diffusion layer may
need to request that data from peers, so a hybrid request/response and pub/sub
model is needed.

## Implementation

### Request/response

  - Nothing new is needed. time-warp conversations can already do this, and
    already are being used to do this in cardano-sl.

  - What's required is to move these conversations into the diffusion layer.
    That will be a part of the work described [here](./Interface.md).

### Pub/sub and reusing existing implementation

The outbound queue in time-warp serves the same role that the pub half of
pub/sub will: getting data out to peers. It has some features we no longer need,
and is missing some that we will need.

  - It already has a notion of subscription, but it's topicless (or rather,
    there's one topic called "everything"), so we'll have to introduce topics.
    Each topic subscription is controlled by its own conversation, just as the
    "everything" subscription is at the moment.
    This way, the subscription protocol can remain mostly as is. The subscriber
    sends an empty subscribe message and periodically sends empty keepalive
    messages if the channel has been quiet for long enough.
    The publisher will send messages (start conversations) of a type determined
    by the topic, to every subscriber of the topic.

  - It decides where to route messages according to a policy and peer
    classification (`NodeType`) based on a topology configuration.
    We'll get rid of this and replace it with a simple policy in which every
    message is delivered to every subscriber for the relevant topic.
    The `Peers` type will be simplified, since there's no longer a notion of
    alternatives (`EnqueueOne` versus `EnqueueAll`), and renamed to
    `Subscribers` to avoid confusion with the peer roster.

  - Subscription buckets won't be necessary. These are used to organize a
    set of mutable `Peers` values so that they can be modified concurrently
    by independent users. With pub/sub there will only be one `Peers`
    (`Subscribers`) value and one modifier: the subscription listener.

  - Rate limiting, precedence, max ahead will probably still be useful, both
    for publishing and for requesting.

  - Enqueue and dequeue policies aren't useful as is, because there is no
    `NodeType`.

  - Failure policy isn't relevant for for pub/sub. If the peer fails then the
    subscription is gone and won't return unless the subscriber tries again.
    We'll probably want to keep the notion of a failure policy around, because
    it is relevant for request/reponse. However, it won't be a part of pub/sub,
    but rather the QoS/delta-Q system and peer roster, where failures will
    lower the estimate and eventually cause the peer to fall out of favour.

  - The mechanism for enqueueing requests (conversations) can remain as is
    besides changing the form of enqueue and dequeue policies, and making sure
    to source the potential peers from the peer roster rather than from the set
    of current subscribers (at the moment these are easily confused in the
    buckets of `Peers`).

## Questions, caveats, risks

### Publish over subscription channel

It would make a lot of sense to send the published data over the same
conversation which is used to establish the subscription, rather than (as we
do now) have one conversation control the lifetime of the connection, and
starting other conversations to publish each datum.

It's not clear whether this has any big advantages or disadvantages.

### Changes to time-warp

The goal should be to do minimal changes to time-warp. It already enables
what we need to do, but not in the most efficient or straightforward way.

### Topic filtering

Should this be done at publisher or subscriber?
Doing it at the publisher will reduce network traffic but the publisher will
have to do more work. Doing it at the subscriber offloads the filtering work
to the subscriber. Filtering won't be expensive (a pattern match) so it's
probably best to do it at the publisher.

### Dead subscriptions due to half-open connections

cardano-sl pull request
[#1852](https://github.com/input-output-hk/cardano-sl/pull/1852) was made to fix
[CSL-1676] and is relevant to pub/sub. We'll keep this solution or something
like it in order to detect dead subscriptions.

### Number of subscribers

Each subscription will be served by one TCP connection, so the OS imposes a
limit on the number of subscribers. It's plausible that even far below this
limit performance will start to suffer. But it's also plausible that the number
of subscriptions actually needed per node is low enough (not more than a
hundred) to avoid any such problems.
There's already a maximum subscribers configuration in the outbound queue that
can be reused.

The `ConccurentMultiQueue` used now to enqueue conversations may not be
suitable for use with a large number of subscribers.
