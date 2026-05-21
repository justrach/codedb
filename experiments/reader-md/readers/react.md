---
schema_version: 1
generated_at: 2026-05-21T00:00:00Z
generator: "claude-sonnet-4-6"
source_hash: "blake2b:1a84ee5e65bb0a864f33bb66fc396435"
source_files:
  - packages/react/src/ReactClient.js
  - packages/react/src/ReactHooks.js
  - packages/react-reconciler/src/ReactFiberLane.js
  - packages/react-reconciler/src/ReactFiberWorkLoop.js
  - packages/react-reconciler/src/ReactFiberHooks.js
  - packages/react-reconciler/src/ReactFiberBeginWork.js
  - packages/scheduler/src/forks/Scheduler.js
  - packages/react-dom/src/client/ReactDOMRoot.js
loc_budget: 200
loc_actual: 95
---

# react

Concurrent UI runtime. The public `react` package is a thin dispatcher layer;
all reconciliation lives in `react-reconciler`, all DOM work in `react-dom-bindings`,
and cooperative scheduling in `scheduler`. The compiler (`compiler/`) is a
separate opt-in tree transform and does not affect the runtime.

## Layout

- `packages/react/src/` — public API surface
  - `ReactClient.js` — canonical export list; re-exports from sub-modules
  - `ReactHooks.js` — every hook delegates to `ReactSharedInternals.H` (the dispatcher)
- `packages/react-reconciler/src/` — the entire fiber engine (~50 files)
  - `ReactFiberWorkLoop.js` — render/commit orchestration (5 600 L, load-bearing hub)
  - `ReactFiberBeginWork.js` — per-tag reconcile dispatch (`beginWork`)
  - `ReactFiberHooks.js` — hook state machines (mount vs update vs rerender dispatchers)
  - `ReactFiberLane.js` — lane bitmask definitions and lane utility functions
  - `ReactFiberRoot.js` — `FiberRootNode` constructor + `createFiberRoot`
  - `ReactFiber.js` — `FiberNode` constructor, `createWorkInProgress`, alternate pooling
  - `ReactInternalTypes.js` — Flow types for `Fiber`, `FiberRoot`
  - `ReactFiberCommitWork.js` — mutation + layout + passive effect phases
  - `ReactFiberCompleteWork.js` — `completeWork` (bottom-up finalization)
- `packages/react-dom/src/client/`
  - `ReactDOMRoot.js` — `createRoot` / `hydrateRoot`; calls `createContainer`
- `packages/react-dom-bindings/` — host config, DOM event system, property diffing
- `packages/scheduler/src/forks/Scheduler.js` — cooperative task queue (two min-heaps)
- `packages/shared/` — symbols, feature flags, cross-package utilities

## Key concepts

- **Fiber** — unit of work; a JS object with `tag`, `type`, `stateNode`, `lanes`,
  `flags`, `child`, `sibling`, `return`, and `alternate` (double-buffer twin).
- **Lanes** — 31-bit priority bitmask. `SyncLane` = 0b10, 14 `TransitionLane`s,
  4 `RetryLane`s, `IdleLane`, `OffscreenLane`, `DeferredLane`. Lane algebra
  functions live in `ReactFiberLane.js`.
- **Work loop** — `performWorkOnRoot` dispatches to `renderRootSync` or
  `renderRootConcurrent` based on `shouldTimeSlice`. Both drive
  `performUnitOfWork` → `beginWork` / `completeWork`. Concurrent loop calls
  `shouldYieldToHost()` between fibers and exits early if the frame budget
  is exhausted.
- **Scheduler** — independent package; two min-heaps (`taskQueue` / `timerQueue`).
  `unstable_scheduleCallback(priority, cb)` assigns expiration from five priority
  levels. `workLoop` runs tasks until `shouldYieldToHost` or queue empty.
  React reconciler calls this via `scheduleCallback` in `ReactFiberWorkLoop.js`.
- **Hooks** — each hook call goes through `resolveDispatcher()` which reads
  `ReactSharedInternals.H`. The reconciler swaps in `HooksDispatcherOnMount`,
  `HooksDispatcherOnUpdate`, or `HooksDispatcherOnRerender` before calling
  `renderWithHooks`. Hook state is stored as a linked list on `fiber.memoizedState`.
- **Suspense** — throwing a thenable from `renderWithHooks` → caught in
  `throwAndUnwindWorkLoop` → sets `workInProgressSuspendedReason`. On resolution,
  `resolveRetryWakeable` retries via a `RetryLane`. `SuspendedReason` enum has
  9 values covering data, errors, hydration, and server actions.
- **Transitions** — `startTransition` wraps updates in a `TransitionLane`; 14
  lanes allow 14 concurrent in-flight transitions. `requestUpdateLane` checks
  `requestCurrentTransition()` to assign the right lane.

## Entry points

- Add a route / trigger a render → `ReactDOMRoot.js::createRoot` →
  `ReactFiberRoot.js::createFiberRoot` → `scheduleUpdateOnFiber`
- Trace a state update → `scheduleUpdateOnFiber` → `ensureRootIsScheduled` →
  scheduler callback → `performWorkOnRoot` → `renderRootSync/Concurrent` →
  `beginWork` (per fiber) → `commitRoot`
- Add/modify a hook → `ReactFiberHooks.js` (find mount/update pair, e.g.
  `mountReducer` / `updateReducer`)
- Change scheduling priority → `ReactFiberLane.js` + `SchedulerPriorities.js`

## Conventions

- All files are Flow-typed; no TypeScript in the runtime (compiler has TS).
- Feature flags gate every non-trivial branch; flags live in `shared/ReactFeatureFlags.js`
  and are inlined at build time. Never assume a flag is stable.
- `__DEV__` blocks are stripped in production; warnings and extra invariants
  only run in dev builds.
- The reconciler has no direct DOM dependency — it talks through a host config
  (`ReactFiberConfig.js`), which is swapped per renderer at build time.
- `packages/react-noop-renderer/` is the test renderer used in reconciler unit tests.
