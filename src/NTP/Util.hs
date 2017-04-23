{-# LANGUAGE TypeApplications #-}

module NTP.Util
    ( ntpPort
    , resolveNtpHost
    , getCurrentTime
    , preferIPv6
    , selectIPv6
    , selectIPv4
    , withSocketsDoLifted
    ) where

import           Control.Concurrent          (forkIO)
import           Control.Concurrent.STM      (atomically, check)
import           Control.Concurrent.STM.TVar (newTVarIO, readTVar, writeTVar)
import           Control.Monad               (void)
import           Control.Monad.Catch         (MonadMask, bracket, catchAll)
import           Control.Monad.Trans         (MonadIO (..))
import           Data.List                   (find, sortOn)
import           Data.Time.Clock.POSIX       (getPOSIXTime)
import           Data.Time.Units             (Microsecond, fromMicroseconds)
import           Network.Socket              (AddrInfo, AddrInfoFlag (AI_ADDRCONFIG),
                                              Family (AF_INET, AF_INET6), PortNumber (..),
                                              SockAddr (..), SocketType (Datagram),
                                              addrAddress, addrFamily, addrFlags,
                                              addrSocketType, defaultHints, getAddrInfo,
                                              withSocketsDo)

ntpPort :: PortNumber
ntpPort = 123

resolveHost :: String -> (Bool, Bool) -> IO (Maybe SockAddr)
resolveHost host (hasIPv4, hasIPv6) = do
    let hints = defaultHints
            { addrSocketType = Datagram
            , addrFlags = [AI_ADDRCONFIG]  -- since we use AF_INET family
            }
    addrInfos <- getAddrInfo (Just hints) (Just host) Nothing
                    `catchAll` \_ -> return []

    -- one address is enough
    pure $
        if null addrInfos then Nothing
        else if hasIPv6 && hasIPv4 then  Just $ addrAddress $ preferIPv6 addrInfos
        else fmap addrAddress $ if hasIPv4 then selectIPv4 addrInfos else selectIPv6 addrInfos

replacePort :: SockAddr -> PortNumber -> SockAddr
replacePort (SockAddrInet  _ host)            port = SockAddrInet  port host
replacePort (SockAddrInet6 _ flow host scope) port = SockAddrInet6 port flow host scope
replacePort sockAddr                          _    = sockAddr

resolveNtpHost :: String -> (Bool, Bool) -> IO (Maybe SockAddr)
resolveNtpHost host whichSockets = do
    addr <- resolveHost host whichSockets
    return $ flip replacePort ntpPort <$> addr

getCurrentTime :: MonadIO m => m Microsecond
getCurrentTime = liftIO $ fromMicroseconds . round . ( * 1000000) <$> getPOSIXTime

preferIPv6 :: [AddrInfo] -> AddrInfo
preferIPv6 =
    head .
    reverse .
    sortOn addrFamily .
    filter (\a -> addrFamily a == AF_INET6 || addrFamily a == AF_INET)

selectIPv6 :: [AddrInfo] -> Maybe AddrInfo
selectIPv6 = find (\a -> addrFamily a == AF_INET6)

selectIPv4 :: [AddrInfo] -> Maybe AddrInfo
selectIPv4 = find (\a -> addrFamily a == AF_INET)

-- | This function actually creates new thread with `withSocketsDo` applied;
-- this thread is alive as long as given action performs.
-- Naive approach would require `MonadBaseControl IO` which is seldom provided.
withSocketsDoLifted :: (MonadIO m, MonadMask m) => m a -> m a
withSocketsDoLifted action = do
    bracket (liftIO $ newTVarIO False)
            (liftIO . atomically . flip writeTVar True) $
            \exited -> do
                liftIO . void . forkIO $
                    withSocketsDo . atomically $ readTVar exited >>= check
                action
