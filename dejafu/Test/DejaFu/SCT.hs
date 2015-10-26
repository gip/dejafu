{-# LANGUAGE CPP        #-}
{-# LANGUAGE RankNTypes #-}

-- | Systematic testing for concurrent computations.
module Test.DejaFu.SCT
  ( -- * Bounded Partial-order Reduction

  -- | We can characterise the state of a concurrent computation by
  -- considering the ordering of dependent events. This is a partial
  -- order: independent events can be performed in any order without
  -- affecting the result, and so are /not/ ordered.
  --
  -- Partial-order reduction is a technique for computing these
  -- partial orders, and only testing one total order for each partial
  -- order. This cuts down the amount of work to be done
  -- significantly. /Bounded/ partial-order reduction is a further
  -- optimisation, which only considers schedules within some bound.
  --
  -- This module provides both a generic function for BPOR, and also a
  -- pre-emption bounding BPOR runner, which is used by the
  -- "Test.DejaFu" module.
  --
  -- See /Bounded partial-order reduction/, K. Coons, M. Musuvathi,
  -- K. McKinley for more details.

    BacktrackStep(..)
  , sctBounded
  , sctBoundedIO

  -- * Pre-emption Bounding

  -- | BPOR using pre-emption bounding. This adds conservative
  -- backtracking points at the prior context switch whenever a
  -- non-conervative backtracking point is added, as alternative
  -- decisions can influence the reachability of different states.
  --
  -- See the BPOR paper for more details.

  , sctPreBound
  , sctPreBoundIO

  -- * Utilities

  , tidOf
  , decisionOf
  , activeTid
  , preEmpCount
  , initialCVState
  , updateCVState
  , willBlock
  , willBlockSafely
  ) where

import Control.DeepSeq (force)
import Data.Functor.Identity (Identity(..), runIdentity)
import Data.IntMap.Strict (IntMap)
import Data.Sequence (Seq, (|>))
import Data.Maybe (maybeToList, isNothing)
import Test.DejaFu.Deterministic
import Test.DejaFu.Deterministic.IO (ConcIO, runConcIO')
import Test.DejaFu.SCT.Internal

import qualified Data.IntMap.Strict as I
import qualified Data.Sequence as Sq

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative ((<$>), (<*>))
#endif

-- * Pre-emption bounding

-- | An SCT runner using a pre-emption bounding scheduler.
sctPreBound :: MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> Int
  -- ^ The maximum number of pre-emptions to allow in a single
  -- execution
  -> (forall t. Conc t a)
  -- ^ The computation to run many times
  -> [(Either Failure a, Trace)]
sctPreBound memtype pb = sctBounded memtype preEmpCount pb pbBacktrack pbInitialise

-- | Variant of 'sctPreBound' for computations which do 'IO'.
sctPreBoundIO :: MemType -> Int -> (forall t. ConcIO t a) -> IO [(Either Failure a, Trace)]
sctPreBoundIO memtype pb = sctBoundedIO memtype preEmpCount pb pbBacktrack pbInitialise

-- | Count the number of pre-emptions in a schedule prefix.
preEmpCount :: [(Decision, ThreadAction)] -> (Decision, Lookahead) -> Int
preEmpCount ts (d, l) = go ts where
  go ((d, a):rest) = preEmpC (d, Left a) + go rest
  go [] = preEmpC (d, Right l)

  preEmpC (SwitchTo _, Left Yield) = 0
  preEmpC (SwitchTo _, Right WillYield) = 0
  preEmpC (SwitchTo t, _) = if t >= 0 then 1 else 0
  preEmpC _ = 0

-- | Add a backtrack point, and also conservatively add one prior to
-- the most recent transition before that point. This may result in
-- the same state being reached multiple times, but is needed because
-- of the artificial dependency imposed by the bound.
pbBacktrack :: [BacktrackStep] -> Int -> ThreadId -> [BacktrackStep]
pbBacktrack bs i tid = maybe id (\j' b -> backtrack True b j' tid) j $ backtrack False bs i tid where
  -- Index of the conservative point
  j = goJ . reverse . pairs $ zip [0..i-1] bs where
    goJ (((_,b1), (j',b2)):rest)
      | _threadid b1 /= _threadid b2 && not (commit b1) && not (commit b2) = Just j'
      | otherwise = goJ rest
    goJ [] = Nothing

  {-# INLINE pairs #-}
  pairs = zip <*> tail

  commit b = case _decision b of
    (_, CommitRef _ _) -> True
    _ -> False

  -- Add a backtracking point. If the thread isn't runnable, add all
  -- runnable threads.
  backtrack c bx@(b:rest) 0 t
    -- If the backtracking point is already present, don't re-add it,
    -- UNLESS this would force it to backtrack (it's conservative)
    -- where before it might not.
    | t `I.member` _runnable b =
      let val = I.lookup t $ _backtrack b
      in  if isNothing val || (val == Just False && c)
          then b { _backtrack = I.insert t c $ _backtrack b } : rest
          else bx

    -- Otherwise just backtrack to everything runnable.
    | otherwise = b { _backtrack = I.fromList [ (t',c) | t' <- I.keys $ _runnable b ] } : rest

  backtrack c (b:rest) n t = b : backtrack c rest (n-1) t
  backtrack _ [] _ _ = error "Ran out of schedule whilst backtracking!"

-- | Pick a new thread to run. Choose the current thread if available,
-- otherwise add all runnable threads.
pbInitialise :: Maybe (ThreadId, a) -> NonEmpty (ThreadId, b) -> NonEmpty ThreadId
pbInitialise prior threads@((nextTid, _):|rest) = case prior of
  Just (tid, _)
    | any (\(t, _) -> t == tid) $ toList threads -> tid:|[]
  _ -> nextTid:|map fst rest

-- * BPOR

-- | SCT via BPOR.
--
-- Schedules are generated by running the computation with a
-- deterministic scheduler with some initial list of decisions, after
-- which the supplied function is called. At each step of execution,
-- possible-conflicting actions are looked for, if any are found,
-- \"backtracking points\" are added, to cause the events to happen in
-- a different order in a future execution.
--
-- Note that unlike with non-bounded partial-order reduction, this may
-- do some redundant work as the introduction of a bound can make
-- previously non-interfering events interfere with each other.
sctBounded :: Ord d
  => MemType
  -- ^ The memory model to use for non-synchronised @CRef@ operations.
  -> ([(Decision, ThreadAction)] -> (Decision, Lookahead) -> d)
  -- ^ Convert a prefix trace to a bound-specific value
  -> d
  -- ^ The maximum bound
  -> ([BacktrackStep] -> Int -> ThreadId -> [BacktrackStep])
  -- ^ Add a new backtrack point, this takes the history of the
  -- execution so far, the index to insert the backtracking point, and
  -- the thread to backtrack to. This may insert more than one
  -- backtracking point.
  -> (Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, Lookahead) -> NonEmpty ThreadId)
  -- ^ Produce possible scheduling decisions, all will be tried.
  -> (forall t. Conc t a) -> [(Either Failure a, Trace)]
sctBounded memtype bf blim backtrack initialise c = runIdentity $ sctBoundedM memtype bf blim backtrack initialise run where
  run memty sched s = Identity $ runConc' sched memty s c

-- | Variant of 'sctBounded' for computations which do 'IO'.
sctBoundedIO :: Ord d
  => MemType
  -> ([(Decision, ThreadAction)] -> (Decision, Lookahead) -> d) -> d
  -> ([BacktrackStep] -> Int -> ThreadId -> [BacktrackStep])
  -> (Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, Lookahead) -> NonEmpty ThreadId)
  -> (forall t. ConcIO t a) -> IO [(Either Failure a, Trace)]
sctBoundedIO memtype bf blim backtrack initialise c = sctBoundedM memtype bf blim backtrack initialise run where
  run memty sched s = runConcIO' sched memty s c

-- | Generic SCT runner.
sctBoundedM :: (Functor m, Monad m, Ord d)
  => MemType
  -> ([(Decision, ThreadAction)] -> (Decision, Lookahead) -> d) -> d
  -> ([BacktrackStep] -> Int -> ThreadId -> [BacktrackStep])
  -> (Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, Lookahead) -> NonEmpty ThreadId)
  -> (MemType -> Scheduler SchedState -> SchedState -> m (Either Failure a, SchedState, Trace'))
  -- ^ Monadic runner, with computation fixed.
  -> m [(Either Failure a, Trace)]
sctBoundedM memtype bf blim backtrack initialise run = go initialState where
  go bpor = case next bpor of
    Just (sched, conservative, bpor') -> do
      (res, s, trace) <- run memtype (bporSched initialise) (initialSchedState sched)

      let bpoints = findBacktrack memtype backtrack (_sbpoints s) trace
      let newBPOR = pruneCommits . todo (\t d -> bf t d <= blim) bpoints $ grow memtype conservative trace bpor'

      ((res, toTrace trace):) <$> go newBPOR

    Nothing -> return []

-- * BPOR Scheduler

-- | The scheduler state
data SchedState = SchedState
  { _sprefix  :: [ThreadId]
  -- ^ Decisions still to make
  , _sbpoints :: Seq (NonEmpty (ThreadId, Lookahead), [ThreadId])
  -- ^ Which threads are runnable at each step, and the alternative
  -- decisions still to make.
  , _scvstate :: IntMap Bool
  -- ^ The 'CVar' block state.
  }

-- | Initial scheduler state for a given prefix
initialSchedState :: [ThreadId] -> SchedState
initialSchedState prefix = SchedState
  { _sprefix  = prefix
  , _sbpoints = Sq.empty
  , _scvstate = initialCVState
  }

-- | BPOR scheduler: takes a list of decisions, and maintains a trace
-- including the runnable threads, and the alternative choices allowed
-- by the bound-specific initialise function.
bporSched :: (Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, Lookahead) -> NonEmpty ThreadId)
          -> Scheduler SchedState
bporSched initialise = force $ \s prior threads -> case _sprefix s of
  -- If there is a decision available, make it
  (d:ds) ->
    let threads' = fmap (\(t,a:|_) -> (t,a)) threads
        cvstate' = maybe (_scvstate s) (updateCVState (_scvstate s) . snd) prior
    in  (d, s { _sprefix = ds, _sbpoints = _sbpoints s |> (threads', []), _scvstate = cvstate' })

  -- Otherwise query the initialise function for a list of possible
  -- choices, and make one of them arbitrarily (recording the others).
  [] ->
    let threads' = fmap (\(t,a:|_) -> (t,a)) threads
        choices  = initialise prior threads'
        cvstate' = maybe (_scvstate s) (updateCVState (_scvstate s) . snd) prior
        choices' = [t
                   | t  <- toList choices
                   , as <- maybeToList $ lookup t (toList threads)
                   , not . willBlockSafely cvstate' $ toList as
                   ]
    in  case choices' of
          (nextTid:rest) -> (nextTid, s { _sbpoints = _sbpoints s |> (threads', rest), _scvstate = cvstate' })

          -- TODO: abort the execution here.
          [] -> case choices of
                 (nextTid:|_) -> (nextTid, s { _sbpoints = _sbpoints s |> (threads', []), _scvstate = cvstate' })
