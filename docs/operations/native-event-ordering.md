# Native event ordering — upstream fix and ZAQ validation

## Status and evidence

The user authorized updating dependencies after identifying the existing upstream
[jido_ai PR #370](https://github.com/agentjido/jido_ai/pull/370). ZAQ now locks
`jido_ai` at `970575a89631d9be0cc0fa22d380ff1d211fa286` (2.4.0), `jido` 2.4.0 and
`zoi` 0.18.11. The native ordering regressions pass after that update; wider #768
preservation remains in `zaq-emb.31.10`. No local dependency-source patch or new
dispatcher implementation was made. The source trace below describes the old lock.

The real native inspection regression uses Factory, Jido, StreamEvents and
authorized Agent API inspection, with only the remote model replaced by an HTTP
stub. It emits 2,010 **distinct** Unicode deltas, exceeds the native 2,000-event
trace cap, and compares the retained presentation against the exact full text.
Identical repeated characters initially hid event reordering; distinct characters
reproduced corrupted presentation even when the terminal answer was correct.

The real 101-run default-retention regression separately observed completed native
request records with the strategy stuck at `awaiting_llm`. Its retained event tail
included `request_completed` before `llm_completed`/`checkpoint`. Subsequent queries
could reject as busy. This was intermittent before the dependency update; a passing
retry alone was not considered a resolution.

## Historical source trace (`jido_ai` at `fc5bc143`)

1. `deps/jido_ai/lib/jido_ai/reasoning/react/worker/strategy.ex`:
   `run_stream/5` enumerates Runner events and casts them to one worker. The worker
   processes each event and returns `AgentDirective.emit_to_parent/2`.
2. `deps/jido/lib/jido/agent/directive.ex`: `emit_to_parent/3` constructs a PID Emit,
   using asynchronous delivery by default.
3. `deps/jido/lib/jido/agent_server/directive_executors.ex`:
   the Emit executor launches a **separate task for each dispatch**. Events sent
   by different tasks have no single-sender FIFO guarantee.
4. `deps/jido_signal/lib/jido_signal/dispatch/pid.ex`: the asynchronous PID adapter
   itself only sends `{:signal, signal}`; it does not require a dispatch task.
5. `deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex`:
   `apply_runtime_event/2` assigns each event's request as active; `llm_completed`
   sets a final-answer turn to `awaiting_llm`. A late model-completion event can
   therefore reopen the strategy after its terminal event. Late checkpoints can
   also restore a completed request's active ID.

The source trace explains both observed failures. It does **not** establish that
the independent refreshed-Shared first-model timeout (`zaq-emb.31.5`) or any
deployed selected-agent error has this cause.

## Local fixes already covered by preservation

- Factory's exact request reader now requires native `status == :pending` before
  advertising acceptance; a stale active ID cannot authorize terminal control.
- StreamEvents flush updates presentation without reopening lifecycle status.
  This preserves a terminal request's final zero buffered count.
- ServerManager treats an unavailable native shutdown read as requiring its
  existing bounded drain rather than crashing and losing its observation table.
- ServerManager initialization tests now exercise a real supervised restart,
  because protected ETS is owned by that process, not by direct test callbacks.

These extend existing native-reader/stream/lifecycle responsibilities. They do not
reorder native events, reset strategy state, introduce a registry or authorize
recovery for busy/unavailable state.

## Upstream resolution and Zoi compatibility

PR #370 introduces `Jido.AI.Reasoning.ReAct.Worker.EmitEvent`. Its directive
executor casts directly from the worker to the parent instead of using generic
Emit's per-event dispatch tasks. The terminal runtime checkpoint is emitted before
the terminal event. Upstream regressions cover reversed dispatch scheduling,
repeated tool requests and terminal ordering. Generic Emit in `jido` remains
unchanged; it is not the path now used for ReAct request events.

The dependency resolver also updated `jido_signal` 2.3.2, `crontab` 1.2.1,
`phoenix_pubsub` 2.4.1, `telemetry_metrics` 1.2.0 and `time_zone_info` 0.8.0. All
dependencies compiled. Initial ZAQ compilation stopped at OpaqueAliases' removed
`Zoi.Types.Default` struct, as requested by the user's compatibility stop gate.

After separate approval, the obsolete OpaqueAliases wrapper clause was removed.
Zoi 0.18.11 keeps the original schema shape and semantic metadata and stores
defaults as `meta.default == {:value, value}`; existing alias traversal therefore
applies directly. No replacement default application or signing path was added.
The existing default/union regression remains, with an added property for
defaulted-handle expansion, foreign/missing scope denial and explicit nil values.

## Current validation checkpoint

All commands used normal schedulers and unchanged existing timeouts/assertions.

- Current-tree `mix q`: exit 0, no subprocess error; hooks passed; Credo checked
  1,544 files / 19,013 modules/functions with no issues; docs generated.
- Alias/native inspection/HTTP flow suites, seed 625: 31 tests and 2 properties
  passed, including distinct-character long-stream ordering, default 100-request
  eviction/reuse, historical inspection isolation, archive authorization and teardown.
- Expanded Agent / Conversations / Channels / workflow / email / media / ratings
  matrix, seed 625, four ExUnit cases: **2,357 tests, 59 properties, 17 doctests,
  zero failures**, 21 excluded by existing project tags.
- Alias/native inspection/HTTP/nested-agent repeat, seed 2026: 38 tests and
  2 properties passed.
- A five-file repeat including all history-strategy flows, seed 0, ran 75 tests
  and 2 properties with one Shared owner-followup committed-delivery timeout.
  Alias/native ordering cases passed. The active-update cases subsequently passed
  unchanged in isolation (10 tests, seed 0). This intermittent acceptance failure
  remains recorded in `.31.10`; it was not fixed, skipped or attributed to ordering.

## Remaining limits

Do not claim complete #768 acceptance from the green dependency checkpoint. Real
busy-admission closure, the delivery-timeout investigation, independent `.31.5`
diagnosis and integrated acceptance remain open, along with human behavior/E2E,
review/coverage, final precommit and separately authorized publication/merge.
