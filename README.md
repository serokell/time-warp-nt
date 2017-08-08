# time-warp-nt

Repository for modeling ideas of distributed systems networking and implementing sketches of these ideas.

## Overview

### Node

Node is a fundamental part of distributed system. Each node has:

1. transport endpoint (network-transport)
2. internal state
3. thread for dispatching different network events

Note that each node muse have exclusive reign over a network-transport
*endpoint*, but not necessarily an entire transport; one transpart can support
multiple nodes via multiple endpoints.

Each node defines a set of listeners as a pure function of some system-wide
peer data type.

## Examples

You can find usage examples in `examples` directory. Start from the simplest one, PingPong.
