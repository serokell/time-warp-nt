{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

module JsonLog.Event
    ( JLTimed (..)
    , JLTimedEvent (..)
    , toEvent
    , fromEvent
    , timedIO
    , Handler (..)
    , handleEvent
    ) where

import Control.Monad.IO.Class (MonadIO)
import Data.Aeson 
import Data.Time.Units        (Microsecond)

import Mockable.CurrentTime   (realTime)

data JLTimed a = JLTimed !Microsecond !a
    deriving (Show, Functor)

instance ToJSON a => ToJSON (JLTimed a) where

    toJSON = toJSON . toEvent

instance FromJSON a => FromJSON (JLTimed a) where

    parseJSON v = do
        JLTimedEvent (JLTimed ts v') <- parseJSON v
        x                            <- parseJSON v'
        return $ JLTimed ts x

newtype JLTimedEvent = JLTimedEvent { runJLTimedEvent :: JLTimed Value }
    deriving Show

instance ToJSON JLTimedEvent where

    toJSON (JLTimedEvent (JLTimed ts v)) = object
        [ "timestamp" .= (fromIntegral ts :: Integer)
        , "event"     .= v
        ]

instance FromJSON JLTimedEvent where

    parseJSON = withObject "JLTimedEvent" $ \v -> JLTimedEvent <$> 
        (JLTimed
            <$> (f <$> v .: "timestamp")
            <*>        v .: "event")
      where
        f :: Integer -> Microsecond
        f = fromIntegral

toEvent :: ToJSON a => JLTimed a -> JLTimedEvent
toEvent = JLTimedEvent . fmap toJSON

fromEvent :: forall a. FromJSON a => JLTimedEvent -> JLTimed (Either Value a)
fromEvent = fmap f . runJLTimedEvent
  where
    f :: Value -> Either Value a
    f v = case fromJSON v of
        Error _   -> Left v
        Success x -> Right x

timedIO :: MonadIO m => a -> m (JLTimed a)
timedIO x = realTime >>= \ts -> return (JLTimed ts x)

data Handler a where

    Handler :: FromJSON b => (JLTimed b -> a) -> Handler a

handleEvent :: (JLTimed Value -> a)
            -> [Handler a] 
            -> JLTimedEvent 
            -> a
handleEvent def hs e = go hs
  where
    go []                = def $ runJLTimedEvent e
    go (Handler h : hs') = case fromEvent e of
        JLTimed ts (Right x) -> h (JLTimed ts x)
        _                    -> go hs'
