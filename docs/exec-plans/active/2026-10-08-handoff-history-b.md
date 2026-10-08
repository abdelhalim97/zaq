# History B — human behavior approval handoff

## Goal

Complete #768's second outcome: Person-bound agents consume authorized durable
history and complete reliably without duplicate context, lost inputs, leaked
private execution data or false delivery confirmation. The user authorized local
implementation and validated commits through the human approval step, not PR B
publication or merge.

## Current State

- Branch: `feature/issue-768-history-b-execution`. Implementation is committed
  through `4fe3d6312`; the tree was clean before adding this handoff. All 39
  existing stashes were preserved; none was applied or dropped.
- PR B is local-only, based exactly on PR A's inspected `a0c8796e` tip. No new
  prerequisite PR, draft closure, push, merge or branch rewrite was performed.
- `.7` removal, `.8` delayed delivery and `.29` topology reconciliation are closed.
  `.31` integrated validation is closed; `.32` is awaiting explicit human
  behavior/UX gate, not final implementation approval.
- Latest preservation runs after the compatibility fixes passed separately with
  `--max-cases 4`: Channels plus 41 related Engine/People suites **2,111 tests /
  43 properties**; Agent, canonical Conversations and removal contract **1,992
  tests / 56 properties / 17 doctests**. These suites overlap; do not sum them as
  unique coverage. Existing integration/ParadeDB/real-browser exclusions remain.
- `mix q` passed using `ERL_FLAGS="+S 1:1"`, with checks unchanged. The final
  implementation commit hooks also passed; diff checks were clean.
- A fresh isolated database applied the migration chain after standard
  `mix db.extensions` bootstrap and passed **2,055 tests / 57 properties /
  17 doctests** before the last compatibility corrections. This run includes
  empty/populated execution-receipt rollback/reapply preservation. The temporary
  database was removed; the working database was not reset. Current-tree suites
  separately reran the migration regression.
- PR A #835 is still draft/open at `a0c8796e`, based on the preserved facts branch.
  Native PostgreSQL, ParadeDB, optional Elixir, format, Credo, docs, Chromium and
  WebKit CI passed. Firefox was cancelled after roughly six hours; aggregate
  User Journeys QA failed because its matrix was cancelled. A rerun request was
  rejected by the token: `Resource not accessible by personal access token`.
- PR A's prior approval does not approve B. New B browser E2E, PR B publication,
  review/coverage, final `mix precommit`, final approval and merge are still pending.
  The unrelated `zaq-mcw` and `zaq-e8q` global-validation investigations remain open.

## Active files

All listed implementation changes are committed. This handoff is the only new
documentation artifact; no scratch code or untracked implementation remains.

| File | State | Role |
| --- | --- | --- |
| `docs/services/agent.md` | Committed | Runtime removal and output-fencing contract |
| `docs/services/channels.md` | Committed | Delayed delivery and confirmation boundaries |
| `docs/services/engine.md` | Committed | Transactional removal publication and generation contract |
| `docs/services/message-lifecycle.md` | Committed | Full capture/execution/synchronization/delivery sequence |
| `lib/zaq/agent/api.ex` | Committed | Trusted removal event and terminal/fallback suppression |
| `lib/zaq/agent/executor.ex` | Committed | Removal guards and exact error scope/credential binding |
| `lib/zaq/agent/factory.ex` | Committed | Native cancellation and stream-sink wakeup |
| `lib/zaq/agent/history_lifecycle.ex` | Committed | Stable principal/generation binding and cancelled waiters |
| `lib/zaq/agent/pipeline.ex` | Committed | Preserve execution disposition through result conversion |
| `lib/zaq/agent/request_registry.ex` | Committed | Immutable consumer ownership and removal tombstones |
| `lib/zaq/agent/server_manager.ex` | Committed | Person/source/exact-PID cancellation and delayed-generation fencing |
| `lib/zaq/agent/stream_events.ex` | Committed | Buffered output fencing and internal failure scope |
| `lib/zaq/contracts/history_runtime_removal.ex` | Committed, new | Bounded provider-neutral notification shape |
| `lib/zaq/engine/channel_history_membership.ex` | Committed | Authoritative removed-Person diff and transactional generation |
| `lib/zaq/engine/conversations/execution_history.ex` | Committed | Initial source generations and nil-source legacy compatibility |
| `lib/zaq/engine/history_runtime_removal.ex` | Committed, new | Post-commit fanout and retry staging |
| `lib/zaq/engine/history_runtime_removal_worker.ex` | Committed, new | Transactional notification retry adapter |
| `test/zaq/agent/history_context_sync_test.exs` | Committed | Removal, waiter, rollback, incarnation and stale-generation regressions |
| `test/zaq/channels/mattermost_shared_history_integration_test.exs` | Committed | Actual Jido/LLM/HTTP removal and delayed terminal acceptance |
| `test/zaq/channels/person_credential_ingress_integration_test.exs` | Committed | Person recovery/disposal preservation and real owner completion barrier |
| `test/zaq/contracts/history_runtime_removal_test.exs` | Committed, new | Payload safety properties |
| `test/zaq/engine/channel_history_membership_test.exs` | Committed | Surviving membership and snapshot-generation preservation |
| `test/zaq/engine/conversations/execution_history_test.exs` | Committed | Verified legacy connector admission, owner/token/delta guards |
| `docs/exec-plans/active/2026-10-08-handoff-history-b.md` | New artifact | This approval handoff |

## Changes Made

- `ec1b3b7f9`: committed removal cancels the affected Person's channel and inherited
  thread runtimes, fences output and wakes consumers. Failed private execution
  remains auditable; unrelated people/sources and manual grants survive.
  Initial Engine-owned source generations prevent old notifications from stopping
  newly authorized replacements. Effects are never executed on rollback.
- `a97daf568`: actual asynchronous delivery tests exercise a full Arabic answer,
  delayed success, delayed gateway timeout and the real HTTP receive deadline.
  Completed generation exists before confirmation; only a confirmed receipt
  creates history placement. Late HTTP responses and association retries do not
  become transport resends or false acknowledgements.
- `4fe3d6312`: restored Person-specific credential recovery and exact failed-runtime
  disposal using the reducer's internal scope. Fixed legacy connector inputs
  crashing on an Ecto nil-provider comparison without relaxing admission owner,
  token or canonical-placement checks. Added completion synchronization to the
  credential preservation fixture without weakening its original assertions.
- The earlier B commits already cover fixed-cursor cumulative model-turn refresh,
  canonical deduplication, retained tool pairs, private roots/receipts/accounting,
  actual input-consumption evidence and admission held through persisted outcomes
  and confirmed native context/cursor application. Current preservation suites
  exercise those contracts alongside this continuation.
- User decisions remain unchanged: preserve accepted broader A ancestry, original
  drafts, applied migrations and existing data; bugs belong to their owning PR;
  no provider interpretation in Agent/Engine; separate A/B human acceptance.

## Failed attempts

- Killing Jido alone left the stream consumer waiting indefinitely. Native
  cancellation plus fenced sink wakeup now terminates it without consumption claims.
- Event-ID receipts alone could cancel a newly authorized replacement on delayed
  first delivery. Initial source-generation fencing now covers that case.
- A delivery fixture initially blocked the full streaming intermediary rather than
  the terminal edit. It now permits that intermediary and blocks the subsequent
  terminal transport operation; generation is verified independently in the test.
- A removal assertion initially inspected a thread's membership marker. Membership
  belongs to its parent; the actual inherited source-generation assertion was fixed.
- Expanded tests exposed the Person credential guidance and legacy nil-provider
  failures. Both received owning-B fixes and unchanged existing tests now pass.
- A combined preservation attempt exceeded 600 seconds; subsequent narrower runs
  exposed transient shared-sandbox checkout failures. A direct answering test
  passed unchanged in isolation; credential fixture completion now waits for its
  real execution owner. Final two preservation runs passed with four test cases.
- Default/four-scheduler ExDNA checks repeatedly hit their internal five-second
  deadline under heavy browser load. Single-scheduler quality checks passed with
  no exclusions. Single-scheduler application tests were unsuitable because test
  database pool size derives from scheduler count; normal schedulers were retained
  for tests, with bounded ExUnit concurrency instead.
- A 180-second local commit attempt timed out while its hook continued. No hook
  was skipped; a 600-second retry completed and committed successfully.
- PR A CI rerun was blocked by token permissions, not an observed browser assertion.

## Next step

1. **Blocked on user:** approve or request changes to PR B's live behavior: shared
   history remains Person-bound; own busy inputs steer one root; cumulative context
   and tool exchanges survive warm reuse; removal stops output while surviving
   manual access allows restart; only confirmed terminal delivery associates the
   completed answer. Record exact approver/date/scope in `zaq-emb.32`.
2. **Ready after approval:** unblock `.13.2` and author/run consolidated B browser
   E2E; then review, fresh coverage and final `mix precommit` before final approval.
3. **Blocked on user/CI credentials:** rerun the cancelled Firefox/aggregate checks
   on PR A or provide a token authorized to rerun them. Reconcile A's validation
   separately; do not label its cancelled matrix green.
4. **Ready:** retain `.31` evidence and reconcile `zaq-mcw`/`zaq-e8q` at the actual
   final validation gate; current scoped passes do not close unrelated flakes.

Do not self-approve UX, author new B browser E2E before approval, push/merge B,
rewrite or close preserved drafts, reset populated databases, kill unrelated
browser processes, weaken assertions, or claim final validation is complete.
