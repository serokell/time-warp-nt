module Main where

import           Control.Applicative        (empty)
import           Control.Monad              (unless)
import           Data.Time.Units            (Second)
import           GHC.IO.Encoding            (setLocaleEncoding, utf8)
import qualified Network.Transport.TCP      as TCP
import           Options.Applicative.Simple (simpleOptions)
import           Serokell.Util.Concurrent   (threadDelay)
import           System.Random              (mkStdGen)
import           System.Wlog                (usingLoggerName)

import           Bench.Network.Commons      (MeasureEvent (..), Ping (..), Pong (..),
                                             loadLogConfig, logMeasure)
import           Network.Transport.Concrete (concrete)
import           Node                       (Listener (..), ListenerAction (..), sendTo,
                                             startNode, stopNode)
import           ReceiverOptions            (Args (..), argsParser)


main :: IO ()
main = do
    (Args {..}, ()) <-
        simpleOptions
            "bench-receiver"
            "Server utility for benches"
            "Use it!"
            argsParser
            empty

    loadLogConfig logsPrefix logConfig
    setLocaleEncoding utf8

    Right transport_ <- TCP.createTransport ("127.0.0.1") (show port)
        TCP.defaultTCPParameters
    let transport = concrete transport_

    let prng = mkStdGen 0

    usingLoggerName "receiver" $ do
        receiverNode <- startNode transport prng []
            -- TODO: call them "ping" & "pong"
            [Listener "ping" $ pingListener noPong]

        threadDelay $ (fromIntegral duration :: Second)
        stopNode receiverNode
  where
    pingListener noPong =
        -- TODO: `ListenerActionConversation` is not supported in such context
        -- why? how should it be used then?
        ListenerActionOneMsg $ \peerId sendActions (Ping mid payload) -> do
            logMeasure PingReceived mid payload
            unless noPong $ do
                logMeasure PongSent mid payload
                sendTo sendActions peerId "pong" $ Pong mid payload