{-# LANGUAGE FlexibleContexts #-}

module Main where

import           Control.Applicative        (empty)
import           Control.Monad              (forM_, liftM2)
import           Control.Monad.Random       (evalRandT, getRandomR)
import           Control.Monad.Trans        (lift, liftIO)
import           Data.Time.Units            (Second)
import           GHC.IO.Encoding            (setLocaleEncoding, utf8)
import           Options.Applicative.Simple (simpleOptions)
import           Serokell.Util.Concurrent   (threadDelay)
import           System.Random              (mkStdGen)
import           System.Wlog                (usingLoggerName)

import           Bench.Network.Commons      (MeasureEvent (..), Payload (..), Ping (..),
                                             Pong (..), loadLogConfig, logMeasure)
import           Network.Transport.Concrete (concrete)
import qualified Network.Transport.TCP      as TCP
import           Node                       (Listener (..), ListenerAction (..), sendTo,
                                             startNode, stopNode)
import           Node.Internal              (NodeId (..))
import           SenderOptions              (Args (..), argsParser)


sendDelay :: Maybe Int -> Second
sendDelay Nothing     = 0
sendDelay (Just rate) = fromIntegral $ 1000000 `div` rate

main :: IO ()
main = do
    (Args {..}, ()) <-
        simpleOptions
            "bench-sender"
            "Sender utility for benches"
            "Use it!"
            argsParser
            empty

    loadLogConfig logsPrefix logConfig
    setLocaleEncoding utf8

    Right transport_ <- TCP.createTransport ("127.0.0.1") "3432"
        TCP.defaultTCPParameters
    let transport = concrete transport_

    let prngNode = mkStdGen 0
    let prngWork = mkStdGen 1
    let nodeIds  = [ NodeId $ TCP.encodeEndPointAddress host (show port) 0
                   | (host, port) <- recipients ]
    let delay    = sendDelay msgRate
    let tasksIds = [[tid, tid + threadNum .. msgNum] | tid <- [1..threadNum]]

    usingLoggerName "sender" $ do
        senderNode <- startNode transport prngNode
            -- TODO: is it good idea to start (recipients number * thread number) threads?
            (liftM2 (pingSender prngWork payloadBound delay)
                tasksIds
                (zip [0, msgNum..] nodeIds))
            [Listener "pong" pongListener]

        threadDelay (fromIntegral duration :: Second)
        stopNode senderNode
  where
    pongListener = ListenerActionOneMsg $ \_ _ (Pong mid payload) ->
        logMeasure PongReceived mid payload

    pingSender gen payloadBound delay msgIds (msgStartId, peerId) sendActions = do
        flip evalRandT gen . forM_ msgIds $
            \msgId -> do
                let sMsgId = msgStartId + msgId
                payload <- liftIO $ Payload <$> getRandomR (0, payloadBound)
                lift $ logMeasure PingSent sMsgId payload
                -- TODO: better to use `connect` + `send`,
                -- but `connect` is not implemented yet
                lift $ sendTo sendActions peerId "ping" $ Ping sMsgId payload
                threadDelay delay