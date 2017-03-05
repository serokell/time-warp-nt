{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}

module Mockable.SharedAtomic (

      SharedAtomicT
    , SharedAtomic(..)
    , newSharedAtomic
    , readSharedAtomic
    , tryTakeSharedAtomic
    , tryPutSharedAtomic
    , modifySharedAtomic
    , withSharedAtomic

    ) where

import           Mockable.Class (MFunctor' (hoist'), Mockable (liftMockable))

type family SharedAtomicT (m :: * -> *) :: * -> *

data SharedAtomic (m :: * -> *) (t :: *) where
    NewSharedAtomic :: t -> SharedAtomic m (SharedAtomicT m t)
    ModifySharedAtomic :: SharedAtomicT m s -> (s -> m (s, t)) -> SharedAtomic m t
    ReadSharedAtomic :: SharedAtomicT m t -> SharedAtomic m t
    TryTakeSharedAtomic :: SharedAtomicT m t -> SharedAtomic m (Maybe t)
    TryPutSharedAtomic :: SharedAtomicT m t -> t -> SharedAtomic m Bool

instance (SharedAtomicT n ~ SharedAtomicT m) => MFunctor' SharedAtomic m n where
    hoist' _ (NewSharedAtomic t)               = NewSharedAtomic t
    hoist' nat (ModifySharedAtomic var update) = ModifySharedAtomic var (\s -> nat $ update s)
    hoist' _ (ReadSharedAtomic sat)            = ReadSharedAtomic sat
    hoist' _ (TryTakeSharedAtomic sat)         = TryTakeSharedAtomic sat
    hoist' _ (TryPutSharedAtomic sat t)        = TryPutSharedAtomic sat t

{-# INLINE newSharedAtomic #-}
newSharedAtomic :: ( Mockable SharedAtomic m ) => t -> m (SharedAtomicT m t)
newSharedAtomic t = liftMockable $ NewSharedAtomic t

{-# INLINE readSharedAtomic #-}
readSharedAtomic :: ( Mockable SharedAtomic m ) => SharedAtomicT m t -> m t
readSharedAtomic sat = liftMockable $ ReadSharedAtomic sat

{-# INLINE tryTakeSharedAtomic #-}
tryTakeSharedAtomic :: (Mockable SharedAtomic m) => SharedAtomicT m t -> m (Maybe t)
tryTakeSharedAtomic sat = liftMockable $ TryTakeSharedAtomic sat

{-# INLINE tryPutSharedAtomic #-}
tryPutSharedAtomic :: (Mockable SharedAtomic m) => SharedAtomicT m t -> t -> m Bool
tryPutSharedAtomic sat t = liftMockable $ TryPutSharedAtomic sat t

{-# INLINE modifySharedAtomic #-}
modifySharedAtomic
    :: ( Mockable SharedAtomic m )
    => SharedAtomicT m s
    -> (s -> m (s, t))
    -> m t
modifySharedAtomic sat f = liftMockable $ ModifySharedAtomic sat f

{-# INLINE withSharedAtomic #-}
withSharedAtomic
    :: ( Mockable SharedAtomic m )
    => SharedAtomicT m s
    -> (s -> m t)
    -> m t
withSharedAtomic sat f = liftMockable $ ModifySharedAtomic sat g
    where
    g s = fmap ((,) s) (f s)
