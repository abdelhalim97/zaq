# Late-steering sealing race — investigation brief

**Status:** local implementation and isolated recovery regressions pass; broader
preservation/quality validation and acceptance gates remain open (2026-10-09).
Tracking: `zaq-emb.31.7`, within [#768](https://github.com/www-zaq-ai/zaq/issues/768).
This retains the original observed-problem brief below as historical evidence.

## Local resolution checkpoint

The subsequently approved focused plan removes `RequestRegistry`, uses native Jido
request authority with retained ServerManager presentation, and addresses executions
explicitly. A proven closed-before-accept incoming correction reserves the same
incarnation's FIFO history lease, waits for prior persistence/context synchronization,
then prepares one fresh root linked to its unchanged receipt and enters the normal
pipeline. It is a bounded live handoff, not a durable retry scheduler. See the
current [Agent contract](../services/agent.md#agent-api--executor) and
[Engine contract](../services/engine.md) for ownership/capability semantics.

Four real sealing cases pass: native-complete/consumer-lag ordinary admission,
closure after actual discovery/queueing with one `Hola` followup and immutable
receipt, native sealed-queue `closed` recovery, and removal during that wait with no
recovery root/model run. Lifecycle
checks cover expiry, dead callers, FIFO ordering, exact lease adoption, replacement,
abort and waiting-input removal fences. Engine checks cover finalized-before-queue
disposition, consumed denial and capability/accounting replay. No push, deployment,
full acceptance or final approval is claimed; `.31.5` remains independent.

## Historical investigation (before the approved implementation)

## Problem

A same-Person correction can arrive after the native Jido request has completed
but before ZAQ's stream consumer records completion in `RequestRegistry`.
ZAQ consequently tries to steer an already-completed request. The correction is
persisted as an **unconsumed private input receipt**, but no follow-up execution
starts. Factual message history is retained; the requested correction is not answered.

## What is already fixed

Local commit `95b0e726a` fixes a separate active-status lookup defect:
`RequestRegistry.find_active/3` previously recognized only `:running` and
`:streaming`, missing `:tool_running` and `:tool_completed`.

Six production-path cases now pass, including an actual 10-second sleep followed
by a 5-second sleep and a Spanish correction. Corrections during real tools,
reasoning/text streaming and a silent next-model call produce one `Hola` answer,
one answer-owning root, a native consumed-input receipt, two tool calls and three
model calls. A correction after fully recorded completion starts a normal follow-up.
Ownership, configured-agent, scope, exact-runtime, removal and terminal fences
remain unchanged. This commit has not been pushed or verified in the deployed app.

## Deterministic reproduction of the remaining race

The uncommitted regression is in
`test/zaq/channels/history_strategy_full_flow_test.exs`, tagged
`steering_phase: :sealing_race`.

```sh
mix test test/zaq/channels/history_strategy_full_flow_test.exs --only steering_phase:sealing_race --seed 625
```

The test exercises real provider ingress, Engine authorization/admission,
persistence, Jido, registered sleep tools, Agent control and delivery. Only remote
provider/model HTTP is replaced. Barriers control timing without fabricated native
events or manually assigned registry statuses:

1. Complete two real tool calls and pause the final model response.
2. Verify the registry reports `:tool_completed` for the original request.
3. Temporarily suspend that request's actual stream consumer.
4. Release the model response and await **native Jido completion**.
5. Ingress `@zaq actually in Spanish` from the same Person and exact scope.
6. Observe durable input queueing, then resume the stream consumer.
7. Require a follow-up model request; none arrives.

Observed diagnostics:

```text
late correction did not become a followup; receipt status=unconsumed
async dispatch failed ... action=run_pipeline ... reason={:rejected, :idle}
```

The original answer completes and is delivered. The correction has no new
answer-owning execution. Suspension deliberately exposes the ordering window;
this proves the behavior is possible, not its frequency in ordinary operation.

## Owning paths and why a simple fallback is unsafe

- `lib/zaq/agent/request_registry.ex`: active lookup sees the not-yet-finalized record.
- `lib/zaq/agent/request_control.ex`: queues the durable child receipt **before**
  invoking native steering; native refusal is retained and returned as an error.
- `lib/zaq/agent/api.ex`: the error branch does not dispatch a follow-up pipeline.
- `lib/zaq/engine/conversations/execution_lifecycle.ex`: rejection/finalization
  retains `unconsumed` receipt evidence; children never own public answers.
- `lib/zaq/engine/conversations/execution_record.ex`: loaded ownership/capability
  identity, assigned receipt root and terminal status cannot be rebound/reopened.
- `lib/zaq/engine/conversations.ex`: finalization rejects a child capability with
  `:input_not_root`; admission/finalization capabilities are currently Message-bound.

Therefore, merely returning `:not_active` after native refusal would reuse an
already-linked child admission as though it were a fresh answer root. Promoting
or resetting that child would violate the existing receipt contract.

**Schema clarification:** `execution_records.user_message_id` has a nonunique
index, not a database uniqueness constraint. Current lifecycle lookups nevertheless
assume one execution record per input. Creating another record alone would make
those input-only lookups ambiguous and would not establish valid capability,
finalization or accounting semantics. Capability hashes and public-answer linkage
do have uniqueness protection. Earlier tracking shorthand about input uniqueness
must not be interpreted as an existing database constraint.

## Evidence, limits and stopping point

- Before adding the race regression: **198 tests, 9 properties, 6 doctests passed**
  across registry, StreamEvents, API, Executor and history-strategy suites.
- With the preserved regression: **199 tests, 9 properties, 6 doctests, one failure**
  at seed 625; that failure is exactly the late-follow-up race. The isolated race
  also fails. `mix q` and `git diff --check` pass.
- The user's deployed Japanese-answer plus selected-agent-error reproduction has
  not been traced end to end. Do not claim this exact race caused that error.
- The refreshed-Shared concurrent first-model timeout (`zaq-emb.31.5`) remains a
  separate unresolved problem.
- No retry implementation, persistence migration, receipt promotion, skipped test,
  weakened assertion, push, deployment, final approval or merge was performed.
  Earlier queue/revocation/handoff work remains preserved.

The unresolved design question is how to admit an authorized follow-up after a
**proven native refusal**, while retaining the original immutable receipt and
canonical input UUID, rejecting consumed/ambiguous inputs, and maintaining one
answer/accounting owner. That design was not completed or approved. Work stops
with the failing regression intact, not with a claimed full steering resolution.
