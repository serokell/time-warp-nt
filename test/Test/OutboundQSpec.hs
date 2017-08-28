{-# LANGUAGE ScopedTypeVariables #-}
module Test.OutboundQSpec
       ( spec
       ) where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.List                             (delete)
import qualified Data.Map.Strict                       as M
import qualified Data.Set                              as Set
import           Data.Text                             (Text)
import           Formatting                            (sformat, shown, (%))
import qualified Mockable                              as M
import           Mockable.Production                   (Production,
                                                        runProduction)
import qualified Network.Broadcast.OutboundQueue       as OutQ
import           Network.Broadcast.OutboundQueue.Demo
import           Network.Broadcast.OutboundQueue.Types hiding (simplePeers)
import qualified Network.Transport                     as NT (Transport)
import qualified Network.Transport.Abstract            as NT
import           System.Wlog
import           Test.Hspec                            (Spec, afterAll_,
                                                        describe, it, runIO,
                                                        shouldBe)
import           Test.Hspec.QuickCheck                 (modifyMaxSuccess, prop)
import           Test.QuickCheck                       (Property, choose,
                                                        generate, ioProperty)
import           Test.QuickCheck.Modifiers             (NonEmptyList (..),
                                                        getNonEmpty)
import           Test.Util                             (HeavyParcel (..),
                                                        Parcel (..),
                                                        Payload (..), TestState,
                                                        deliveryTest, expected,
                                                        makeInMemoryTransport,
                                                        makeTCPTransport,
                                                        mkTestState,
                                                        modifyTestState,
                                                        newWork, receiveAll,
                                                        sendAll, timeout)

testInFlight :: IO Bool
testInFlight = do
    -- Set up some test nodes
    allNodes <- M.runProduction $ do
      ns <- forM [1..4] $ \nodeIdx -> newNode (C nodeIdx) NodeCore  (CommsDelay 0)
      forM_ ns $ \theNode -> setPeers theNode  (delete theNode ns)
      return ns

    runEnqueue $ do
      -- Send messages asynchronously
      forM_ [1..10] $ \n -> do
        rIdx <- liftIO $ generate $ choose (0, 3)
        send Asynchronous (allNodes !! rIdx) (MsgTransaction OriginSender) (MsgId n)

    -- Verify the invariants
    let queues = map nodeOutQ allNodes
    forM_ queues OutQ.flush

    allInFlights <- mapM OutQ.currentlyInFlight queues
    return $ all allGreaterThanZero allInFlights

allGreaterThanZero :: M.Map NodeId (M.Map OutQ.Precedence Int) -> Bool
allGreaterThanZero imap = all (>= 0) $ (concatMap M.elems (M.elems imap))

spec :: Spec
spec = describe "OutBoundQ" $ modifyMaxSuccess (const 2000) $ do
  -- Simulate a multi-peer conversation and then check
  -- that after that we never have a negative count for
  -- the `qInFlight` field of a `OutBoundQ`.
  it "inflight conversations" $ ioProperty $ testInFlight
