{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}

module JsonLog.JsonLogT
    ( JsonLogT
    , runWithoutJsonLogT
    , runJsonLogT
    , runJsonLogT'
    , runWithJsonLogT
    , runWithJsonLogT'
    ) where

import Control.Concurrent.MVar        (MVar, withMVar)
import Control.Monad.Base             (MonadBase)
import Control.Monad.Fix              (MonadFix)
import Control.Monad.IO.Class         (MonadIO (..))
import Control.Monad.Morph            (MFunctor (..)) 
import Control.Monad.Trans.Class      (MonadTrans)
import Control.Monad.Trans.Control    (MonadBaseControl (..))
import Control.Monad.Trans.Lift.Local (LiftLocal)
import Control.Monad.Trans.Reader     (ReaderT (..))
import Data.Aeson                     (encode)
import Data.ByteString.Lazy           (hPut)
import Formatting                     (sformat, shown, (%))
import Serokell.Util.Lens             (WrappedM (..))
import System.IO                      (Handle)
import System.Wlog.CanLog             (CanLog, WithLogger, logWarning)
import System.Wlog.LoggerNameBox      (HasLoggerName (..))
import Universum                      hiding (catchAll)

import JsonLog.CanJsonLog             (CanJsonLog (..))
import JsonLog.Event                  (JLTimedEvent, toEvent, timedIO)
import Mockable.Class                 (Mockable (..))
import Mockable.Channel               (ChannelT, Channel)
import Mockable.Concurrent            (Concurrently, Promise, Async, Delay, Fork, ThreadId)
import Mockable.CurrentTime           (CurrentTime)
import Mockable.Instances             (liftMockableWrappedM)
import Mockable.Exception             (Bracket, Throw, Catch, catchAll)
import Mockable.Metrics               (Gauge, Counter, Distribution, Metrics)
import Mockable.SharedAtomic          (SharedAtomicT, SharedAtomic)
import Mockable.SharedExclusive       (SharedExclusiveT, SharedExclusive)

type R = Maybe (MVar Handle, JLTimedEvent -> IO Bool)

newtype JsonLogT m a = JsonLogT (ReaderT R m a)
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, MFunctor, 
              MonadThrow, MonadCatch, MonadMask, MonadFix, MonadBase b, LiftLocal)

instance MonadBaseControl b m => MonadBaseControl b (JsonLogT m) where

    type StM (JsonLogT m) a = StM m a

    liftBaseWith f = JsonLogT $ liftBaseWith $ \g -> f (g . packM)

    restoreM = unpackM . restoreM

instance WithLogger m => CanLog (JsonLogT m) where

instance WithLogger m => HasLoggerName (JsonLogT m) where

    getLoggerName = lift getLoggerName

    modifyLoggerName f = hoist (modifyLoggerName f)

instance Monad m => WrappedM (JsonLogT m) where

    type UnwrappedM (JsonLogT m) = ReaderT R m

    unpackM = JsonLogT

    packM (JsonLogT m) = m

type instance Gauge (JsonLogT m) = Gauge m
type instance Counter (JsonLogT m) = Counter m
type instance Distribution (JsonLogT m) = Distribution m
type instance ThreadId (JsonLogT m) = ThreadId m
type instance Promise (JsonLogT m) = Promise m
type instance SharedAtomicT (JsonLogT m) = SharedAtomicT m
type instance SharedExclusiveT (JsonLogT m) = SharedExclusiveT m
type instance ChannelT (JsonLogT m) = ChannelT m

instance Mockable Catch m => Mockable Catch (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable Throw m => Mockable Throw (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable Bracket m => Mockable Bracket (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable Fork m => Mockable Fork (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable Delay m => Mockable Delay (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable Async m => Mockable Async (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable Concurrently m => Mockable Concurrently (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable CurrentTime m => Mockable CurrentTime (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable SharedAtomic m => Mockable SharedAtomic (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable SharedExclusive m => Mockable SharedExclusive (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance Mockable Channel m => Mockable Channel (JsonLogT m) where

    liftMockable = liftMockableWrappedM


instance Mockable Metrics m => Mockable Metrics (JsonLogT m) where

    liftMockable = liftMockableWrappedM

instance ( MonadIO m
         , WithLogger m
         , Mockable Catch m) => CanJsonLog (JsonLogT m) where

    jsonLog x = JsonLogT $ do
        mv <- ask
        case mv of
            Nothing -> return ()
            Just (v, decide) -> do
                event <- toEvent <$> timedIO x
                b     <- liftIO (decide event)
                    `catchAll` \e -> do
                        logWarning $ sformat ("error in deciding whether to json log: "%shown) e
                        return False
                when b $ liftIO (withMVar v $ flip hPut $ encode event)
                    `catchAll` \e ->
                        logWarning $ sformat ("can't write json log: "%shown) e

runWithoutJsonLogT :: JsonLogT m a -> m a
runWithoutJsonLogT (JsonLogT m) = runReaderT m Nothing

runJsonLogT :: MonadIO m => Maybe (Handle, JLTimedEvent -> IO Bool) -> JsonLogT m a -> m a
runJsonLogT Nothing            m            = runWithoutJsonLogT m
runJsonLogT (Just (h, decide)) (JsonLogT m) = do
    v <- newMVar h
    runReaderT m $ Just (v, decide)

runJsonLogT' :: MonadIO m => Maybe Handle -> JsonLogT m a -> m a
runJsonLogT' mh = runJsonLogT $ fmap (\h -> (h, const $ return True)) mh

runWithJsonLogT :: MonadIO m => Handle -> (JLTimedEvent -> IO Bool) -> JsonLogT m a -> m a
runWithJsonLogT h decide = runJsonLogT $ Just (h, decide)

runWithJsonLogT' :: MonadIO m => Handle -> JsonLogT m a -> m a
runWithJsonLogT' = runJsonLogT' . Just
