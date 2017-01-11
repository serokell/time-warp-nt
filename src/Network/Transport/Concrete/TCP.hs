{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}

module Network.Transport.Concrete.TCP
    ( concreteTCP
    ) where

import           Control.Monad.IO.Class (MonadIO)
import           Network.Transport.Abstract
import           Network.Transport.Concrete (concrete)
import qualified Network.Transport     as NT
import qualified Network.Transport.TCP as TCP

-- | Use a TCP transport and its internals to create an abstract
--   Transport over any MonadIO m which also has an arrow back into IO.
concreteTCP
    :: forall m .
       ( MonadIO m )
    => (forall t . m t -> IO t)
    -> (NT.Transport, TCP.TransportInternals)
    -> Transport m
concreteTCP lowerIO (transport, internals) = concrete newEndPoint closeTransport
    where
    newEndPoint :: Policy m -> IO (Either (TransportError NewEndPointErrorCode) NT.EndPoint)
    newEndPoint policy = TCP.newEndPointInternal internals tcpPolicy
        where
        tcpPolicy = lowerPolicy lowerIO policy
    closeTransport :: IO ()
    closeTransport = NT.closeTransport transport

lowerPolicy :: (forall t . m t -> IO t) -> Policy m -> TCP.Policy
lowerPolicy lowerIO tcpPolicy addr = lowerPolicyDecision lowerIO (tcpPolicy addr)

lowerPolicyDecision
    :: (forall t . m t -> IO t)
    -> PolicyDecision m
    -> TCP.PolicyDecision
lowerPolicyDecision lowerIO (PolicyDecision pdecision) = TCP.PolicyDecision $ do
    (decision, next) <- lowerIO pdecision
    let continue = lowerPolicyDecision lowerIO next
    pure $ case decision of
        Accept -> (TCP.Accept, continue)
        Block until -> (TCP.Block (lowerIO until), continue)
