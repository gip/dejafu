{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Test.DejaFu.Conc.Internal
-- Copyright   : (c) 2016--2018 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : FlexibleContexts, MultiWayIf, RankNTypes, RecordWildCards
--
-- Concurrent monads with a fixed scheduler: internal types and
-- functions. This module is NOT considered to form part of the public
-- interface of this library.
module Test.DejaFu.Conc.Internal where

import           Control.Exception                   (Exception,
                                                      MaskingState(..),
                                                      toException)
import qualified Control.Monad.Conc.Class            as C
import           Data.Foldable                       (foldrM, toList)
import           Data.Functor                        (void)
import           Data.List                           (sortOn)
import qualified Data.Map.Strict                     as M
import           Data.Maybe                          (fromMaybe, isJust,
                                                      isNothing)
import           Data.Monoid                         ((<>))
import           Data.Sequence                       (Seq, (<|))
import qualified Data.Sequence                       as Seq
import           GHC.Stack                           (HasCallStack)

import           Test.DejaFu.Conc.Internal.Common
import           Test.DejaFu.Conc.Internal.Memory
import           Test.DejaFu.Conc.Internal.STM
import           Test.DejaFu.Conc.Internal.Threading
import           Test.DejaFu.Internal
import           Test.DejaFu.Schedule
import           Test.DejaFu.Types

--------------------------------------------------------------------------------
-- * Set-up

-- | 'Trace' but as a sequence.
type SeqTrace
  = Seq (Decision, [(ThreadId, Lookahead)], ThreadAction)

-- | The result of running a concurrent program.
data CResult n g a = CResult
  { finalContext :: Context n g
  , finalRef :: C.IORef n (Maybe (Either Failure a))
  , finalRestore :: Maybe (Threads n -> n ())
  -- ^ Meaningless if this result doesn't come from a snapshotting
  -- execution.
  , finalTrace :: SeqTrace
  , finalDecision :: Maybe (ThreadId, ThreadAction)
  }

-- | A snapshot of the concurrency state immediately after 'dontCheck'
-- finishes.
--
-- @since 1.4.0.0
data DCSnapshot n a = DCSnapshot
  { dcsContext :: Context n ()
  -- ^ The execution context.  The scheduler state is ignored when
  -- restoring.
  , dcsRestore :: Threads n -> n ()
  -- ^ Action to restore IORef, MVar, and TVar values.
  , dcsRef :: C.IORef n (Maybe (Either Failure a))
  -- ^ Reference where the result will be written.
  }

-- | Run a concurrent computation with a given 'Scheduler' and initial
-- state, returning a failure reason on error. Also returned is the
-- final state of the scheduler, and an execution trace.
runConcurrency :: (C.MonadConc n, HasCallStack)
  => Bool
  -> Scheduler g
  -> MemType
  -> g
  -> IdSource
  -> Int
  -> ModelConc n a
  -> n (CResult n g a)
runConcurrency forSnapshot sched memtype g idsrc caps ma = do
  let ctx = Context { cSchedState = g
                    , cIdSource   = idsrc
                    , cThreads    = M.empty
                    , cWriteBuf   = emptyBuffer
                    , cCaps       = caps
                    }
  res <- runConcurrency' forSnapshot sched memtype ctx ma
  killAllThreads (finalContext res)
  pure res

-- | Run a concurrent program using the given context, and without
-- killing threads which remain at the end.  The context must have no
-- main thread.
--
-- Only a separate function because @ADontCheck@ needs it.
runConcurrency' :: (C.MonadConc n, HasCallStack)
  => Bool
  -> Scheduler g
  -> MemType
  -> Context n g
  -> ModelConc n a
  -> n (CResult n g a)
runConcurrency' forSnapshot sched memtype ctx ma = do
  (c, ref) <- runRefCont AStop (Just . Right) (runModelConc ma)
  let threads0 = launch' Unmasked initialThread (const c) (cThreads ctx)
  threads <- (if C.rtsSupportsBoundThreads then makeBound initialThread else pure) threads0
  runThreads forSnapshot sched memtype ref ctx { cThreads = threads }

-- | Like 'runConcurrency' but starts from a snapshot.
runConcurrencyWithSnapshot :: (C.MonadConc n, HasCallStack)
  => Scheduler g
  -> MemType
  -> Context n g
  -> (Threads n -> n ())
  -> C.IORef n (Maybe (Either Failure a))
  -> n (CResult n g a)
runConcurrencyWithSnapshot sched memtype ctx restore ref = do
  let boundThreads = M.filter (isJust . _bound) (cThreads ctx)
  threads <- foldrM makeBound (cThreads ctx) (M.keys boundThreads)
  restore threads
  res <- runThreads False sched memtype ref ctx { cThreads = threads }
  killAllThreads (finalContext res)
  pure res

-- | Kill the remaining threads
killAllThreads :: (C.MonadConc n, HasCallStack) => Context n g -> n ()
killAllThreads ctx =
  let finalThreads = cThreads ctx
  in mapM_ (`kill` finalThreads) (M.keys finalThreads)

-------------------------------------------------------------------------------
-- * Execution

-- | The context a collection of threads are running in.
data Context n g = Context
  { cSchedState :: g
  , cIdSource   :: IdSource
  , cThreads    :: Threads n
  , cWriteBuf   :: WriteBuffer n
  , cCaps       :: Int
  }

-- | Run a collection of threads, until there are no threads left.
runThreads :: (C.MonadConc n, HasCallStack)
  => Bool
  -> Scheduler g
  -> MemType
  -> C.IORef n (Maybe (Either Failure a))
  -> Context n g
  -> n (CResult n g a)
runThreads forSnapshot sched memtype ref = schedule (const $ pure ()) Seq.empty Nothing where
  -- signal failure & terminate
  die reason finalR finalT finalD finalC = do
    C.writeIORef ref (Just $ Left reason)
    stop finalR finalT finalD finalC

  -- just terminate; 'ref' must have been written to before calling
  -- this
  stop finalR finalT finalD finalC = pure CResult
    { finalContext  = finalC
    , finalRef      = ref
    , finalRestore  = if forSnapshot then Just finalR else Nothing
    , finalTrace    = finalT
    , finalDecision = finalD
    }

  -- check for termination, pick a thread, and call 'step'
  schedule restore sofar prior ctx
    | isTerminated  = stop restore sofar prior ctx
    | isDeadlocked  = die Deadlock restore sofar prior ctx
    | isSTMLocked   = die STMDeadlock restore sofar prior ctx
    | otherwise =
      let ctx' = ctx { cSchedState = g' }
      in case choice of
           Just chosen -> case M.lookup chosen threadsc of
             Just thread
               | isBlocked thread -> die InternalError restore sofar prior ctx'
               | otherwise ->
                 let decision
                       | Just chosen == (fst <$> prior) = Continue
                       | (fst <$> prior) `notElem` map (Just . fst) runnable' = Start chosen
                       | otherwise = SwitchTo chosen
                     alternatives = filter (\(t, _) -> t /= chosen) runnable'
                 in step decision alternatives chosen thread restore sofar prior ctx'
             Nothing -> die InternalError restore sofar prior ctx'
           Nothing -> die Abort restore sofar prior ctx'
    where
      (choice, g')  = scheduleThread sched prior (efromList runnable') (cSchedState ctx)
      runnable'     = [(t, lookahead (_continuation a)) | (t, a) <- sortOn fst $ M.assocs runnable]
      runnable      = M.filter (not . isBlocked) threadsc
      threadsc      = addCommitThreads (cWriteBuf ctx) threads
      threads       = cThreads ctx
      isBlocked     = isJust . _blocking
      isTerminated  = initialThread `notElem` M.keys threads
      isDeadlocked  = M.null (M.filter (not . isBlocked) threads) &&
        (((~=  OnMVarFull  undefined) <$> M.lookup initialThread threads) == Just True ||
         ((~=  OnMVarEmpty undefined) <$> M.lookup initialThread threads) == Just True ||
         ((~=  OnMask      undefined) <$> M.lookup initialThread threads) == Just True)
      isSTMLocked = M.null (M.filter (not . isBlocked) threads) &&
        ((~=  OnTVar []) <$> M.lookup initialThread threads) == Just True

  -- run the chosen thread for one step and then pass control back to
  -- 'schedule'
  step decision alternatives chosen thread restore sofar prior ctx = do
      (res, actOrTrc, actionSnap) <- stepThread
          forSnapshot
          (isNothing prior)
          sched
          memtype
          chosen
          (_continuation thread)
          ctx
      let sofar' = sofar <> getTrc actOrTrc
      let prior' = getPrior actOrTrc
      let restore' threads' =
            if forSnapshot
            then restore threads' >> actionSnap threads'
            else restore threads'
      let ctx' = fixContext chosen res ctx
      case res of
        Succeeded _ ->
          schedule restore' sofar' prior' ctx'
        Failed failure ->
          die failure restore' sofar' prior' ctx'
        Snap _ ->
          stop actionSnap sofar' prior' ctx'
    where
      getTrc (Single a) = Seq.singleton (decision, alternatives, a)
      getTrc (SubC as _) = (decision, alternatives, Subconcurrency) <| as

      getPrior (Single a) = Just (chosen, a)
      getPrior (SubC _ finalD) = finalD

-- | Apply the context update from stepping an action.
fixContext :: ThreadId -> What n g -> Context n g -> Context n g
fixContext chosen (Succeeded ctx@Context{..}) _ =
  ctx { cThreads = delCommitThreads $
        if (interruptible <$> M.lookup chosen cThreads) /= Just False
        then unblockWaitingOn chosen cThreads
        else cThreads
      }
fixContext _ (Failed _) ctx@Context{..} =
  ctx { cThreads = delCommitThreads cThreads }
fixContext _ (Snap ctx@Context{..}) _ =
  ctx { cThreads = delCommitThreads cThreads }

-- | @unblockWaitingOn tid@ unblocks every thread blocked in a
-- @throwTo tid@.
unblockWaitingOn :: ThreadId -> Threads n -> Threads n
unblockWaitingOn tid = fmap $ \thread -> case _blocking thread of
  Just (OnMask t) | t == tid -> thread { _blocking = Nothing }
  _ -> thread

--------------------------------------------------------------------------------
-- * Single-step execution

-- | What a thread did, for trace purposes.
data Act
  = Single ThreadAction
  -- ^ Just one action.
  | SubC SeqTrace (Maybe (ThreadId, ThreadAction))
  -- ^ @subconcurrency@, with the given trace and final action.
  deriving (Eq, Show)

-- | What a thread did, for execution purposes.
data What n g
  = Succeeded (Context n g)
  -- ^ Action succeeded: continue execution.
  | Failed Failure
  -- ^ Action caused computation to fail: stop.
  | Snap (Context n g)
  -- ^ Action was a snapshot point and we're in snapshot mode: stop.

-- | Run a single thread one step, by dispatching on the type of
-- 'Action'.
--
-- Each case looks very similar.  This is deliberate, so that the
-- essential differences between actions are more apparent, and not
-- hidden by accidental differences in how things are expressed.
--
-- Note: the returned snapshot action will definitely not do the right
-- thing with relaxed memory.
stepThread :: (C.MonadConc n, HasCallStack)
  => Bool
  -- ^ Should we record a snapshot?
  -> Bool
  -- ^ Is this the first action?
  -> Scheduler g
  -- ^ The scheduler.
  -> MemType
  -- ^ The memory model to use.
  -> ThreadId
  -- ^ ID of the current thread
  -> Action n
  -- ^ Action to step
  -> Context n g
  -- ^ The execution context.
  -> n (What n g, Act, Threads n -> n ())
-- start a new thread, assigning it the next 'ThreadId'
stepThread _ _ _ _ tid (AFork n a b) = \ctx@Context{..} -> pure $
  let (idSource', newtid) = nextTId n cIdSource
      threads' = launch tid newtid a cThreads
  in ( Succeeded ctx { cThreads = goto (b newtid) tid threads', cIdSource = idSource' }
     , Single (Fork newtid)
     , const (pure ())
     )

-- start a new bound thread, assigning it the next 'ThreadId'
stepThread _ _ _ _ tid (AForkOS n a b) = \ctx@Context{..} -> do
  let (idSource', newtid) = nextTId n cIdSource
  let threads' = launch tid newtid a cThreads
  threads'' <- makeBound newtid threads'
  pure ( Succeeded ctx { cThreads = goto (b newtid) tid threads'', cIdSource = idSource' }
       , Single (ForkOS newtid)
       , const (pure ())
       )

-- check if the current thread is bound
stepThread _ _ _ _ tid (AIsBound c) = \ctx@Context{..} -> do
  let isBound = isJust . _bound $ elookup tid cThreads
  pure ( Succeeded ctx { cThreads = goto (c isBound) tid cThreads }
       , Single (IsCurrentThreadBound isBound)
       , const (pure ())
       )

-- get the 'ThreadId' of the current thread
stepThread _ _ _ _ tid (AMyTId c) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto (c tid) tid cThreads }
       , Single MyThreadId
       , const (pure ())
       )

-- get the number of capabilities
stepThread _ _ _ _ tid (AGetNumCapabilities c) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto (c cCaps) tid cThreads }
       , Single (GetNumCapabilities cCaps)
       , const (pure ())
       )

-- set the number of capabilities
stepThread _ _ _ _ tid (ASetNumCapabilities i c) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto c tid cThreads, cCaps = i }
       , Single (SetNumCapabilities i)
       , const (pure ())
       )

-- yield the current thread
stepThread _ _ _ _ tid (AYield c) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto c tid cThreads }
       , Single Yield
       , const (pure ())
       )

-- yield the current thread (delay is ignored)
stepThread _ _ _ _ tid (ADelay n c) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto c tid cThreads }
       , Single (ThreadDelay n)
       , const (pure ())
       )

-- create a new @MVar@, using the next 'MVarId'.
stepThread _ _ _ _ tid (ANewMVar n c) = \ctx@Context{..} -> do
  let (idSource', newmvid) = nextMVId n cIdSource
  ref <- C.newIORef Nothing
  let mvar = ModelMVar newmvid ref
  pure ( Succeeded ctx { cThreads = goto (c mvar) tid cThreads, cIdSource = idSource' }
       , Single (NewMVar newmvid)
       , const (C.writeIORef ref Nothing)
       )

-- put a value into a @MVar@, blocking the thread until it's empty.
stepThread _ _ _ _ tid (APutMVar mvar@ModelMVar{..} a c) = synchronised $ \ctx@Context{..} -> do
  (success, threads', woken, effect) <- putIntoMVar mvar a c tid cThreads
  pure ( Succeeded ctx { cThreads = threads' }
       , Single (if success then PutMVar mvarId woken else BlockedPutMVar mvarId)
       , const effect
       )

-- try to put a value into a @MVar@, without blocking.
stepThread _ _ _ _ tid (ATryPutMVar mvar@ModelMVar{..} a c) = synchronised $ \ctx@Context{..} -> do
  (success, threads', woken, effect) <- tryPutIntoMVar mvar a c tid cThreads
  pure ( Succeeded ctx { cThreads = threads' }
       , Single (TryPutMVar mvarId success woken)
       , const effect
       )

-- get the value from a @MVar@, without emptying, blocking the thread
-- until it's full.
stepThread _ _ _ _ tid (AReadMVar mvar@ModelMVar{..} c) = synchronised $ \ctx@Context{..} -> do
  (success, threads', _, _) <- readFromMVar mvar c tid cThreads
  pure ( Succeeded ctx { cThreads = threads' }
       , Single (if success then ReadMVar mvarId else BlockedReadMVar mvarId)
       , const (pure ())
       )

-- try to get the value from a @MVar@, without emptying, without
-- blocking.
stepThread _ _ _ _ tid (ATryReadMVar mvar@ModelMVar{..} c) = synchronised $ \ctx@Context{..} -> do
  (success, threads', _, _) <- tryReadFromMVar mvar c tid cThreads
  pure ( Succeeded ctx { cThreads = threads' }
       , Single (TryReadMVar mvarId success)
       , const (pure ())
       )

-- take the value from a @MVar@, blocking the thread until it's full.
stepThread _ _ _ _ tid (ATakeMVar mvar@ModelMVar{..} c) = synchronised $ \ctx@Context{..} -> do
  (success, threads', woken, effect) <- takeFromMVar mvar c tid cThreads
  pure ( Succeeded ctx { cThreads = threads' }
       , Single (if success then TakeMVar mvarId woken else BlockedTakeMVar mvarId)
       , const effect
       )

-- try to take the value from a @MVar@, without blocking.
stepThread _ _ _ _ tid (ATryTakeMVar mvar@ModelMVar{..} c) = synchronised $ \ctx@Context{..} -> do
  (success, threads', woken, effect) <- tryTakeFromMVar mvar c tid cThreads
  pure ( Succeeded ctx { cThreads = threads' }
       , Single (TryTakeMVar mvarId success woken)
       , const effect
       )

-- create a new @IORef@, using the next 'IORefId'.
stepThread _ _ _ _  tid (ANewIORef n a c) = \ctx@Context{..} -> do
  let (idSource', newiorid) = nextIORId n cIdSource
  let val = (M.empty, 0, a)
  ioref <- C.newIORef val
  let ref = ModelIORef newiorid ioref
  pure ( Succeeded ctx { cThreads = goto (c ref) tid cThreads, cIdSource = idSource' }
       , Single (NewIORef newiorid)
       , const (C.writeIORef ioref val)
       )

-- read from a @IORef@.
stepThread _ _ _ _  tid (AReadIORef ref@ModelIORef{..} c) = \ctx@Context{..} -> do
  val <- readIORef ref tid
  pure ( Succeeded ctx { cThreads = goto (c val) tid cThreads }
       , Single (ReadIORef iorefId)
       , const (pure ())
       )

-- read from a @IORef@ for future compare-and-swap operations.
stepThread _ _ _ _ tid (AReadIORefCas ref@ModelIORef{..} c) = \ctx@Context{..} -> do
  tick <- readForTicket ref tid
  pure ( Succeeded ctx { cThreads = goto (c tick) tid cThreads }
       , Single (ReadIORefCas iorefId)
       , const (pure ())
       )

-- modify a @IORef@.
stepThread _ _ _ _ tid (AModIORef ref@ModelIORef{..} f c) = synchronised $ \ctx@Context{..} -> do
  (new, val) <- f <$> readIORef ref tid
  effect <- writeImmediate ref new
  pure ( Succeeded ctx { cThreads = goto (c val) tid cThreads }
       , Single (ModIORef iorefId)
       , const effect
       )

-- modify a @IORef@ using a compare-and-swap.
stepThread _ _ _ _ tid (AModIORefCas ref@ModelIORef{..} f c) = synchronised $ \ctx@Context{..} -> do
  tick@(ModelTicket _ _ old) <- readForTicket ref tid
  let (new, val) = f old
  (_, _, effect) <- casIORef ref tid tick new
  pure ( Succeeded ctx { cThreads = goto (c val) tid cThreads }
       , Single (ModIORefCas iorefId)
       , const effect
       )

-- write to a @IORef@ without synchronising.
stepThread _ _ _ memtype tid (AWriteIORef ref@ModelIORef{..} a c) = \ctx@Context{..} -> case memtype of
  -- write immediately.
  SequentialConsistency -> do
    effect <- writeImmediate ref a
    pure ( Succeeded ctx { cThreads = goto c tid cThreads }
         , Single (WriteIORef iorefId)
         , const effect
         )
  -- add to buffer using thread id.
  TotalStoreOrder -> do
    wb' <- bufferWrite cWriteBuf (tid, Nothing) ref a
    pure ( Succeeded ctx { cThreads = goto c tid cThreads, cWriteBuf = wb' }
         , Single (WriteIORef iorefId)
         , const (pure ())
         )
  -- add to buffer using both thread id and IORef id
  PartialStoreOrder -> do
    wb' <- bufferWrite cWriteBuf (tid, Just iorefId) ref a
    pure ( Succeeded ctx { cThreads = goto c tid cThreads, cWriteBuf = wb' }
         , Single (WriteIORef iorefId)
         , const (pure ())
         )

-- perform a compare-and-swap on a @IORef@.
stepThread _ _ _ _ tid (ACasIORef ref@ModelIORef{..} tick a c) = synchronised $ \ctx@Context{..} -> do
  (suc, tick', effect) <- casIORef ref tid tick a
  pure ( Succeeded ctx { cThreads = goto (c (suc, tick')) tid cThreads }
       , Single (CasIORef iorefId suc)
       , const effect
       )

-- commit a @IORef@ write
stepThread _ _ _ memtype _ (ACommit t c) = \ctx@Context{..} -> do
  wb' <- case memtype of
    -- shouldn't ever get here
    SequentialConsistency ->
      fatal "stepThread.ACommit" "Attempting to commit under SequentialConsistency"
    -- commit using the thread id.
    TotalStoreOrder ->
      commitWrite cWriteBuf (t, Nothing)
    -- commit using the IORef id.
    PartialStoreOrder ->
      commitWrite cWriteBuf (t, Just c)
  pure ( Succeeded ctx { cWriteBuf = wb' }
       , Single (CommitIORef t c)
       , const (pure ())
       )

-- run a STM transaction atomically.
stepThread _ _ _ _ tid (AAtom stm c) = synchronised $ \ctx@Context{..} -> do
  let transaction = runTransaction stm cIdSource
  let effect = const (void transaction)
  (res, idSource', trace) <- transaction
  case res of
    Success _ written val -> do
      let (threads', woken) = wake (OnTVar written) cThreads
      pure ( Succeeded ctx { cThreads = goto (c val) tid threads', cIdSource = idSource' }
           , Single (STM trace woken)
           , effect
           )
    Retry touched -> do
      let threads' = block (OnTVar touched) tid cThreads
      pure ( Succeeded ctx { cThreads = threads', cIdSource = idSource'}
           , Single (BlockedSTM trace)
           , effect
           )
    Exception e -> do
      let act = STM trace []
      res' <- stepThrow (const act) tid e ctx
      pure $ case res' of
        (Succeeded ctx', _, effect') -> (Succeeded ctx' { cIdSource = idSource' }, Single act, effect')
        (Failed err, _, effect') -> (Failed err, Single act, effect')
        (Snap _, _, _) -> fatal "stepThread.AAtom" "Unexpected snapshot while propagating STM exception"

-- lift an action from the underlying monad into the @Conc@
-- computation.
stepThread _ _ _ _ tid (ALift na) = \ctx@Context{..} -> do
  let effect threads = runLiftedAct tid threads na
  a <- effect cThreads
  pure (Succeeded ctx { cThreads = goto a tid cThreads }
       , Single LiftIO
       , void <$> effect
       )

-- throw an exception, and propagate it to the appropriate handler.
stepThread _ _ _ _ tid (AThrow e) = stepThrow Throw tid e

-- throw an exception to the target thread, and propagate it to the
-- appropriate handler.
stepThread _ _ _ _ tid (AThrowTo t e c) = synchronised $ \ctx@Context{..} ->
  let threads' = goto c tid cThreads
      blocked  = block (OnMask t) tid cThreads
  in case M.lookup t cThreads of
       Just thread
         | interruptible thread -> stepThrow (ThrowTo t) t e ctx { cThreads = threads' }
         | otherwise -> pure
           ( Succeeded ctx { cThreads = blocked }
           , Single (BlockedThrowTo t)
           , const (pure ())
           )
       Nothing -> pure
         (Succeeded ctx { cThreads = threads' }
         , Single (ThrowTo t False)
         , const (pure ())
         )

-- run a subcomputation in an exception-catching context.
stepThread _ _ _ _ tid (ACatching h ma c) = \ctx@Context{..} -> pure $
  let a     = runModelConc ma (APopCatching . c)
      e exc = runModelConc (h exc) c
  in ( Succeeded ctx { cThreads = goto a tid (catching e tid cThreads) }
     , Single Catching
     , const (pure ())
     )

-- pop the top exception handler from the thread's stack.
stepThread _ _ _ _ tid (APopCatching a) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto a tid (uncatching tid cThreads) }
       , Single PopCatching
       , const (pure ())
       )

-- execute a subcomputation with a new masking state, and give it a
-- function to run a computation with the current masking state.
stepThread _ _ _ _ tid (AMasking m ma c) = \ctx@Context{..} -> pure $
  let resetMask typ ms = ModelConc $ \k -> AResetMask typ True ms $ k ()
      umask mb = resetMask True m' >> mb >>= \b -> resetMask False m >> pure b
      m' = _masking $ elookup tid cThreads
      a  = runModelConc (ma umask) (AResetMask False False m' . c)
  in ( Succeeded ctx { cThreads = goto a tid (mask m tid cThreads) }
     , Single (SetMasking False m)
     , const (pure ())
     )

-- reset the masking thread of the state.
stepThread _ _ _ _ tid (AResetMask b1 b2 m c) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto c tid (mask m tid cThreads) }
       , Single ((if b1 then SetMasking else ResetMasking) b2 m)
       , const (pure ())
       )

-- execute a 'return' or 'pure'.
stepThread _ _ _ _ tid (AReturn c) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto c tid cThreads }
       , Single Return
       , const (pure ())
       )

-- kill the current thread.
stepThread _ _ _ _ tid (AStop na) = \ctx@Context{..} -> do
  na
  threads' <- kill tid cThreads
  pure ( Succeeded ctx { cThreads = threads' }
       , Single Stop
       , const (pure ())
       )

-- run a subconcurrent computation.
stepThread forSnapshot _ sched memtype tid (ASub ma c) = \ctx ->
  if | forSnapshot -> pure (Failed IllegalSubconcurrency, Single Subconcurrency, const (pure ()))
     | M.size (cThreads ctx) > 1 -> pure (Failed IllegalSubconcurrency, Single Subconcurrency, const (pure ()))
     | otherwise -> do
         res <- runConcurrency False sched memtype (cSchedState ctx) (cIdSource ctx) (cCaps ctx) ma
         out <- efromJust <$> C.readIORef (finalRef res)
         pure ( Succeeded ctx
                { cThreads    = goto (AStopSub (c out)) tid (cThreads ctx)
                , cIdSource   = cIdSource (finalContext res)
                , cSchedState = cSchedState (finalContext res)
                }
              , SubC (finalTrace res) (finalDecision res)
              , const (pure ())
              )

-- after the end of a subconcurrent computation. does nothing, only
-- exists so that: there is an entry in the trace for returning to
-- normal computation; and every item in the trace corresponds to a
-- scheduling point.
stepThread _ _ _ _ tid (AStopSub c) = \ctx@Context{..} ->
  pure ( Succeeded ctx { cThreads = goto c tid cThreads }
       , Single StopSubconcurrency
       , const (pure ())
       )

-- run an action atomically, with a non-preemptive length bounded
-- round robin scheduler, under sequential consistency.
stepThread forSnapshot isFirst _ _ tid (ADontCheck lb ma c) = \ctx ->
  if | isFirst -> do
         -- create a restricted context
         threads' <- kill tid (cThreads ctx)
         let dcCtx = ctx { cThreads = threads', cSchedState = lb }
         res <- runConcurrency' forSnapshot dcSched SequentialConsistency dcCtx ma
         out <- efromJust <$> C.readIORef (finalRef res)
         case out of
           Right a -> do
             let threads'' = launch' Unmasked tid (const (c a)) (cThreads (finalContext res))
             threads''' <- (if C.rtsSupportsBoundThreads then makeBound tid else pure) threads''
             pure ( (if forSnapshot then Snap else Succeeded) (finalContext res)
                    { cThreads = threads''', cSchedState = cSchedState ctx }
                  , Single (DontCheck (toList (finalTrace res)))
                  , fromMaybe (const (pure ())) (finalRestore res)
                  )
           Left f -> pure
             ( Failed f
             , Single (DontCheck (toList (finalTrace res)))
             , const (pure ())
             )
     | otherwise -> pure
       ( Failed IllegalDontCheck
       , Single (DontCheck [])
       , const (pure ())
       )

-- | Handle an exception being thrown from an @AAtom@, @AThrow@, or
-- @AThrowTo@.
stepThrow :: (C.MonadConc n, Exception e)
  => (Bool -> ThreadAction)
  -- ^ Action to include in the trace.
  -> ThreadId
  -- ^ The thread receiving the exception.
  -> e
  -- ^ Exception to raise.
  -> Context n g
  -- ^ The execution context.
  -> n (What n g, Act, Threads n -> n ())
stepThrow act tid e ctx@Context{..} = case propagate some tid cThreads of
    Just ts' -> pure
      ( Succeeded ctx { cThreads = ts' }
      , Single (act False)
      , const (pure ())
      )
    Nothing
      | tid == initialThread -> pure
        ( Failed (UncaughtException some)
        , Single (act True)
        , const (pure ())
        )
      | otherwise -> do
          ts' <- kill tid cThreads
          pure ( Succeeded ctx { cThreads = ts' }
               , Single (act True)
               , const (pure ())
               )
  where
    some = toException e

-- | Helper for actions impose a write barrier.
synchronised :: C.MonadConc n
  => (Context n g -> n (What n g, Act, Threads n -> n ()))
  -- ^ Action to run after the write barrier.
  -> Context n g
  -- ^ The original execution context.
  -> n (What n g, Act, Threads n -> n ())
synchronised ma ctx@Context{..} = do
  writeBarrier cWriteBuf
  ma ctx { cWriteBuf = emptyBuffer }

-- | scheduler for @ADontCheck@
dcSched :: Scheduler (Maybe Int)
dcSched = Scheduler go where
  go _ _ (Just 0) = (Nothing, Just 0)
  go prior threads s =
    let (t, _) = scheduleThread roundRobinSchedNP prior threads ()
    in (t, fmap (\lb -> lb - 1) s)
