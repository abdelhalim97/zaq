# History B coverage results — 2026-10-11

## Accepted baseline and validation

Julien ran `mix coveralls.json --seed 6258` successfully on the working tree:
48 doctests, 236 properties, 10,593 tests, zero failures, one skipped, 122 excluded;
850.2s (208.9s async / 641.2s sync). This successful human-run report supersedes the
two agent timeout attempts. It is not an agent-run command. `mix coverup` then
completed successfully and identified the 13 files below; its default comparison
includes stacked PR A changes as well as PR B.

Each file received a separate coverage-planner assessment. Overlapping plans were
merged by test-file ownership before mini-worker implementation. Seven test files
were changed, with no production or dependency changes:

- `test/zaq/agent/idle_lifecycle_test.exs`: touch installs a missing timer.
- `test/zaq/engine/conversations/execution_history_test.exs`: malformed cursors,
  consumed/foreign/unlinked receipts, queued recovery rejection, and real session
  admission retained across receipt rejection, finalization and optional revocation.
- `test/zaq/agent/history_context_sync_test.exs`: reservations, invalid tokens and
  projections, unbound adoption, session pins, retirement access and completion
  cleanup without persistence evidence or after an Engine read error.
- `test/zaq/agent/server_manager_test.exs`: invalid bindings/inspection input,
  idempotent missing-runtime stop, credential-independent runtime survival and
  selective Person credential invalidation.
- `test/zaq/agent/api_test.exs`: malformed public control requests fail before Factory.
- `test/zaq/agent/executor_integration_test.exs`: real admission denial after grant
  revocation, without an LLM call or completed execution.
- `test/zaq/agent/pipeline_test.exs`: actual Hooks registry dispatches a registered
  retrieval-halt handler and preserves the error response's routing.

`mix q` passes: 19,120 modules/functions, no issues. The seven-file targeted
`mix test ... --cover --seed 6258 --max-cases 4` completes with **284 tests /
4 properties, zero failures**, 68.5s. The full suite was not rerun for coverage.
The initial added-test run failed six assertions because of incorrect draft
fixtures/error shapes; those drafts were corrected against public contracts.
In particular, admission is now cached *before* rejection/revocation in the
same live session. The invalid ambiguity fixture was removed because it admitted
a different message, not because the original scenario passed. Existing security
assertions and five-second deadlines remain intact.

## Coverage limits and exceptions

Baseline percentages are the fresh full-run `mix coverup` rounded-down values.
Targeted percentages describe only the seven selected files' execution and are
not comparable full-suite totals. No claim is made that every file reached 95%.

| Production file | Full baseline | Targeted result / remaining assessment |
| --- | ---: | --- |
| `agent/idle_lifecycle.ex` | 81% | 87.5%; remaining two callbacks are no-ops. Additional return-value-only tests would mirror implementation. |
| `engine/workflows/actions/archive_channel_connector.ex` | 83% | Inherited Action: fallback at line 34 requires a collaborator result outside the documented ok/error contract; existing success/error/authorization tests cover supported outcomes. |
| `engine/conversations/execution_history.ex` | 83% | Invalid cursors and real admission paths extended. Remaining malformed internal arguments, unused delta wrapper and missing-parent branches are guarded by facade validation/FKs. Ambiguous placement needs a genuine supported fixture; the attempted unrelated-input fixture did not prove it. |
| `agent/history_sync.ex` | 84% | 88.8%; remaining malformed dispatch responses, post-reservation bind race, exception and exit windows lack deterministic public stimuli without internal doubles. |
| `agent/request_control.ex` | 84% | 48.5% in the narrow run; full native journeys were not rerun for this figure. Remaining receipt/retirement races, duplicate accepting targets and exit windows need deterministic native fixtures. Contract-invalid router responses were not mocked to inflate coverage. |
| `engine/history_delivery_worker.ex` | 87% | Rescue fallback: supported association failures return error tuples. Corrupting persisted confirmation metadata or disrupting infrastructure solely for coverage was rejected. |
| `engine/conversations/execution_lifecycle.ex` | 88% | Added consumed/conflicting/unlinked/queued-recovery cases through Conversations. Remaining post-facade fetch failures, forbidden unadmitted receipts and failed valid status transitions require a distinct real failure fixture. |
| `agent/server_manager.ex` | 90% | 91.1%; deadlines, native ordering and shutdown windows remain. No forged internal state or sleep-based race tests added. Legacy message-shape and impossible owned-result/duplicate-PID branches are separately unreachable under current callers. |
| `engine/history/delivery.ex` | 92% | Unexpected association result and process-exit fallback have no supported deterministic public stimulus; successful/error association preserving transport success is already tested. |
| `agent/executor.ex` | 92% | 83.4% in the narrow run; denial now tested. Native busy-to-queue fallback needs an accepting-runtime fixture distinct from the already tested serialized busy lease. Impossible partial-result/actor/metadata shapes are not fabricated. |
| `agent/pipeline.ex` | 94% | 84.0% in the narrow run; real retrieval hook halt added. Native follow-up propagation and all-search failure still need real deterministic fixtures; malformed successful chunk results violate the search contract. |
| `engine/incoming_message_routing_rule.ex` | 94% | Existing blank-topic and loaded-rule tests cover public behavior. Nonbinary cast and absent-agent checks are preceded by Ecto casting/normalization. No manufactured changesets added. |
| `agent/api.ex` | 94% | 79.9% in the narrow run; malformed controls extended. Native follow-up error/deadline branches remain fixture gaps; impossible validator/Engine response shapes and pre-rejected missing bindings are not forced. |

Paths above are under `lib/zaq/`. Engine execution filenames were truncated in
the targeted textual table; no invented targeted percentage is reported for them.
These are documented coverage exceptions and remaining fixture gaps, not proof of
unreachability for every missed line. Track future meaningful native-race fixtures
separately; do not increase arbitrary retry limits or mock internal acceptance.

## Final gate

The earlier successful human `mix precommit` predates these test additions. The
new agent-run `mix precommit` now passes: exit 0, no timeout/error, 125.871s total;
19,120 modules/functions with no issues, 284 tests / 4 properties, zero failures
(72.0s test phase, seed 124563). This is the alias's stale-test selection, not a
second full 10,593-test run. The existing manual-repro filename and unavailable
license-manager configuration warnings remain non-fatal. No final human acceptance,
commit, push or merge is implied. Coverage follow-up `zaq-68v`, historical delivery
observation `zaq-1wb`, deferred upstream timeout and independent cancellation
defects retain their recorded status.
