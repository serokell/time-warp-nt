{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE StandaloneDeriving #-}

module JsonLog.CanJsonLog
    ( CanJsonLog
    , jsonLog
    , jsonLogWrappedM
    ) where

import Control.Monad.Reader         (ReaderT)
import Control.Monad.State          (StateT)
import Control.Monad.Writer         (WriterT)
import Control.Monad.Trans.Class    (MonadTrans (..))
import Control.Monad.Trans.Identity (IdentityT)
import Data.Aeson.Types             (ToJSON)
import Ether                        (TaggedTrans (..))
import Serokell.Util.Lens           (WrappedM (..))
import System.Wlog.LoggerNameBox    (LoggerNameBox)

class Monad m => CanJsonLog m where

    jsonLog :: ToJSON a => a -> m ()

    default jsonLog :: ( CanJsonLog n
                       , MonadTrans t
                       , m ~ t n
                       , ToJSON a) 
                    => a 
                    -> m ()
    jsonLog x = lift $ jsonLog x

instance CanJsonLog m => CanJsonLog (IdentityT m)
instance CanJsonLog m => CanJsonLog (ReaderT r m)
instance CanJsonLog m => CanJsonLog (StateT s m)
instance (Monoid w, CanJsonLog m) => CanJsonLog (WriterT w m)
instance CanJsonLog m => CanJsonLog (LoggerNameBox m)

deriving instance CanJsonLog m => CanJsonLog (TaggedTrans tag IdentityT m)
deriving instance CanJsonLog m => CanJsonLog (TaggedTrans tag (ReaderT a) m)

jsonLogWrappedM :: (WrappedM m, CanJsonLog (UnwrappedM m), ToJSON a) => a -> m ()
jsonLogWrappedM = unpackM . jsonLog
