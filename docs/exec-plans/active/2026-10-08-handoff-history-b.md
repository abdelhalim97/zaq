# History B — human behavior approval handoff

## 1. Goal

**2026-10-10 superseding decision:** implement admission-time channel-history
authorization and graceful runtime retirement. Accepted input may finish after
membership loss; fresh input/history/inspection remains permission-gated. Provider
removal with surviving manual access does not retire the runtime. The approved
dedicated plan is `/Users/julien/.opencode/plan/768-admission-time-authorization.md`.
Build execution is authorized. Earlier strict-removal cancellation requirements
below are historical, not the current feature contract.

Complete #768's authorized shared channel history and Person-bound execution without
losing canonical identity, private inspection, receipts, accounting or accepted email
behavior. Current authorized scope removes RequestRegistry and recovers definitive
late-steering nonacceptance through one bounded live follow-up, not durable scheduling.

## 2. Current State

**Newest checkpoint — successful human coverage and test-only gap closure (2026-10-11):**
Julien completed `mix coveralls.json --seed 6258`: 48 doctests / 236 properties /
10,593 tests, zero failures, one skipped, 122 excluded, 850.2s. Fresh report is
accepted; this supersedes the earlier coverage timeout blocker. `mix coverup`
identified 13 files below 95%, including stacked A paths. Per-file assessment and
test-only fixes now pass **284 tests / 4 properties** with targeted coverage
(68.5s), and `mix q` reports 19,120 modules/functions with no issues. See
[coverage results and explicit exceptions](../review/history-b-coverage-results.md).
Not all files meet 95%; remaining contract-invalid/race-only branches and missing
deterministic fixtures are documented, not declared covered. New final precommit
passes after the seven test-file changes: exit 0, 125.871s total, 19,120
modules/functions without findings, 284 stale-selected tests / 4 properties with
zero failures (seed 124563). `.33` closed with explicit coverage exceptions tracked
in `zaq-68v`; `.34` awaits final human implementation approval. No commit/push/merge.

**Newest checkpoint — human-approved behavior and consolidated E2E (2026-10-10):**
Julien tested the normal development environment personally and explicitly said
**"I confirm behavior, go ahead"**. `.32` is closed with approver/source/scope
recorded; this authorizes feature E2E, not final acceptance or Git publication.

- Consolidated browser coverage: **21 cases**, Chromium/Firefox/WebKit at both
  mobile and desktop widths. Real ingress/native tools/delivery/persistence,
  persisted measurements/traces after fresh reload, staff denial, concurrent
  Person-owned answers, recipient-only isolation, accepted steering after
  revocation and late linked recovery through retirement. External boundaries
  alone are replaced; normal CSRF login and ephemeral SQL-Sandbox Endpoint.
- Combined browser/native history matrix: **83 tests**, zero failures, seed 0
  (318.7s). The earlier 18-case browser-only matrix passed (133.2s); these overlap.
- Five-file delivery-preservation repeat: **75 tests / 2 properties**, zero
  failures on three seed-0 runs (81.3s, 101.6s, 82.2s). This does **not** establish a cause or fix for the
  historical intermittent committed-delivery failure; `.31.10` remains open.
- Wide seed-0 native preservation/diagnosis: **3,490 tests / 79 properties /
  17 doctests**, zero failures (343.8s), 42 standard/browser exclusions. This is
  not a numerical coverage run or final `mix precommit`. It does not diagnose the
  historical intermittent failure. Existing unused helper/alias compiler warnings
  appeared; the current `mix q` nevertheless passes with no findings.
- [Local implementation review](../review/feature-issue-768-history-b-execution-review.md)
  is approved for coverage with a recorded deferred finding. Julien explicitly
  selected **"Carry unresolved follow-up"**; the historical delivery failure is
  now independent **open `zaq-1wb`**, nonblocking for this validation sequence but
  not fixed. New failures still block. Remaining production paths, migration and
  dependency contracts were inspected; one stale RequestRegistry navigation row
  was corrected. Complementary Engine BO/membership/dispatch/removal/rating matrix
  passes **146 tests / 3 properties**, seed 0 (49.0s). Numerical coverage/final
  precommit have not started; `.33` remains open.
- Browser mobile interaction initially hit the expanded sidebar. The runner now
  closes it through the real Toggle sidebar button, not forced clicks or DOM
  mutation. A first incorrectly combined include/only filter broadened selection;
  that incomplete failing run is not counted as validation.
- New support: `test/support/history_browser.ex`,
  `test/e2e/support/channel-history-browser.cjs`; existing full-flow tests retain
  native coverage, share the concurrency journey, and add browser cases.
  See the [execution guide](../../e2e-testing.md#channel-history-execution-journey-isolated-no-reset).
- The user stopped the port-4002 demo; it was not a spontaneous runtime failure
  and has not been restarted. Stored failure evidence remains. `.31.21` upstream
  report publication remains blocked by GitHub permission; timeout fix deferred.
- Next: fresh coverage per the coverage-upper workflow, then final `mix precommit`.
  Carry the historical delivery investigation in `zaq-1wb`; do not resume it as
  a blocker unless new evidence fails validation. No final acceptance, commit,
  push or merge.

**Coverage retry checkpoint:** the first fresh `mix coveralls.json` failed two
tests (recipient generator exhaustion and stale shared-owner telemetry checkout)
and exceeded its 600-second deadline during reporting/teardown after a 571.8s
test phase. Its JSON is not accepted; `mix coverup` was not run. Newly observed
failures are tracked in `zaq-0vo` / `zaq-m21`, independent from deferred `zaq-1wb`.
Test-only fixes retain exact prior assertions, strengthen reversal invariance and
establish the intended no-owner sandbox state; causal probes are recorded in the
review. Affected 73 tests / 2 properties and `mix q` pass.

**Latest human validation:** Julien subsequently ran `mix precommit` himself and
reported all steps successful: **19,117 modules/functions, no issues; 48 doctests,
236 properties, 10,593 tests, zero failures, one skipped, 122 excluded**, taking
849.0s (135.5s async / 713.4s sync). This is accepted as human-reported current
quality/test-gate evidence; the agent did not rerun it. It does not diagnose or
fix deferred historical `zaq-1wb`. No commit, push or merge is authorized.
The actual precommit alias runs formatting, Credo, compile and stale tests, not
`coveralls.json` or `coverup`; numerical coverage still needs successful human
completion or an explicit human deferral. No previous coverage JSON is accepted.

**Remaining coverage gate:** the fresh retry with `--max-cases 4 --seed 6258` and
unchanged exclusions also timed out at its 600-second deadline (`elapsedMs=600368`,
`error=spawnSync mix ETIMEDOUT`, despite a misleading `status=0`). It produced no
completed ExUnit summary or ExCoveralls completion. Full indexed stdout/stderr and
subprocess metadata are retained under **PR B coverage retry mix coveralls.json
max-cases 4 seed 6258 full output and subprocess metadata**. Logs include a ChatLive
task using a stopped sandbox owner's connection and an MCP initialization
CaseClauseError, neither proven causal or a numbered test failure. No fresh JSON
accepted, no `mix coverup` and no final acceptance. The later successful human
`mix precommit` result is recorded separately above.
Stop automatic coverage progression per the coverage workflow; diagnose the
runtime/completion blocker before another authorized attempt. `zaq-0vo` and
`zaq-m21` remain open pending full-gate validation, independently of deferred
historical delivery follow-up `zaq-1wb`.

**Earlier checkpoint — bounded live behavior shown (2026-10-10):** a fresh isolated
scenario passed with a **92 ms** external model barrier. Real admitted/pending
input → real membership removal → new input failed unadmitted → accepted answer
persisted and delivered via the provider terminal update → exact runtime retired.
The browser shows the answer and **No current grants** together in
[`admission-demo-04-bounded-no-grants.png`](admission-demo-04-bounded-no-grants.png).
Transcript `05bd4630-e520-4265-8f00-3ae4d749b96e`; manual driver
`test/repro/bounded_admission_live_review.exs`. Original stuck demo state was
compared before/after and is untouched; failed fixture attempts are recorded in
the [evidence](../../operations/admission-live-demo-blocker.md).

The earlier long-held request exceeded Jido AI's 75-second native stream deadline.
A database-free Runner reproducer (`test/repro/react_stream_timeout_upstream.exs`)
confirms silent exhaustion after about 1,016 ms at a 1-second deadline, versus
normal prompt completion around 203 ms. Parent/worker source tracing explains
the pending-parent/idle-worker mismatch; the standalone parent harness was
inconclusive, not a completed regression. User explicitly deferred dependency
fixes and requested below-threshold validation plus upstream reporting.

The [upstream report](../../operations/jido-ai-stream-timeout-report.md) includes
an executed self-contained reproduction and suggested terminal-propagation fix.
**Publication failed:** both GitHub CLI and configured integration returned 403
`Resource not accessible by personal access token`; no issue exists to link.
`.31.21` remains open for that publication/follow-up but no longer blocks bounded
`.31.20` validation. No dependency fix is claimed. Latest `mix q` passes; focused
Mattermost/history and HTTP suites pass **27 tests**, zero failures (63.7s).

`.32` behavior approval is still pending; `.31.20`/`.31.10`, consolidated E2E,
review/coverage and final `mix precommit` remain open. Earlier intermittent
committed-delivery failure stays unresolved. No commit/push/merge authorized.

**Earlier checkpoint — long-held live review failed (2026-10-10):** the user chose
**Show live behavior first**, not approval. A fresh branch-isolated E2E database
and separate build run `test/repro/admission_live_demo.exs` on port 4002; no existing
database was reset. Headed Chromium authenticated normally after the embedded
browser stalled on sign-in. The BO shows the accepted input and, after a real
Engine membership-removal event, **No current grants**. A subsequent input is
captured but fails unadmitted. However, releasing the long-held external model
response leaves the original execution pending: native parent `awaiting_llm`,
native worker idle with no task/run/error, manager lease and pin retained.

Evidence and exact diagnostic boundary:
[`docs/operations/admission-live-demo-blocker.md`](../../operations/admission-live-demo-blocker.md).
At that checkpoint `zaq-emb.31.21` blocked `.31.20`; `.32` remained unapproved. The several-minute
manual barrier differs from short automated regressions; cause is unknown, not
a proven membership defect or dependency incompatibility. Preserve the running
local demo and evidence; do not reset native state, weaken tests, treat retries
as resolution, or fix any newly identified dependency incompatibility without
reporting it first. No production/dependency changes were made for this finding.
Current `mix q` and diff checks pass after the manual fixture; no final precommit,
consolidated E2E, coverage, review or publication. The earlier `.31.11` symptom
involved a completed record; do not equate it with this pending-record mismatch.

**Implementation checkpoint (2026-10-10, admission-time continuation):** P1–P5 are locally
implemented and validated; `.31.14`–`.31.19` are closed, including P6 contracts/docs.
P7 `.31.20` and integrated acceptance `.31.10` remain open for finalization gates.

- Core Agent/Engine/Channels matrix: **282 tests / 7 properties, zero failures**
  (137.4s), including post-gate revocation before runtime creation, denied third-turn
  refresh, retired sealing recovery, manual-access survival, and real HTTP-tool
  retirement beyond the old force-drain deadline.
- Wider preservation matrix: **374 tests / 15 properties / 6 doctests, zero
  failures** (76.9s): Executor/Pipeline, nested agents, credential lifecycle,
  inspection/aliases, Engine conversation/migration suites and workflow HTTP pool.
  These matrices overlap; do not add their totals.
- Self-review caught implicit downstream queue admission. Queueing now requires
  recorded child admission; a failing-then-passing regression proves captured
  provisional input/capability alone cannot authorize it. Engine direct fixtures
  enter the real explicit gate. Native callback unit fixtures now use valid
  `GenServer.from` tuples and full history state, not production test affordances.
- Latest `mix q` and `git diff --check` pass against the current tree, including
  the callback-fixture correction and busy-lease scenario. No final
  `mix precommit`, human approval, new browser E2E, review or coverage gate yet.
- `.31.13` closed as **superseded, not fixed**. Independent open follow-ups are
  `zaq-4sl` (native HTTP Action cleanup) and `zaq-t3g` (remote RPC ownership).
  `test/repro/native_http_tool_cancellation.exs` is deliberately opt-in and still
  fails its original five-second borrower-death assertion after native completion.
  The relocated fixture uses the same real internal execution path and external
  API/LLM doubles, without unrelated credential setup. No cancellation fix claimed.
- Membership no longer emits cancellation jobs/events. Runtime-only generations,
  fences and output suppression are removed; ordered provider evidence/tombstones,
  manual grants and inert historical JSON remain. Valid old serialized jobs are
  terminally acknowledged by the inert worker. Source owners updated in
  `docs/services/{agent,engine,message-lifecycle}.md`.
- Real standalone canonical Executor busy-lease coverage now passes: root is held
  at the external LLM; child enters the gate and waits on the exact same lease;
  revocation occurs before root completion; accepted waiter reaches its own real
  model, both roots/answers persist and only then does the runtime retire. The
  first draft selected all manager entries and failed under the combined matrix;
  it now selects immutable connector/transcript/Person/runtime scope. It also
  releases both intentionally held external model calls. Five-second assertions
  remain unchanged. This covers lease admission across root closure, not a claim
  of reproducing an independent native `ask_with_config` busy-refusal race.
- Owner docs local links resolve; production scans find no obsolete cancellation
  plumbing except the intentional serialized-job adapter. All 39 stashes remain.
- Next: obtain separate human behavior approval (`zaq-emb.32`), then consolidated
  browser E2E (`zaq-emb.13.2`), review/coverage and final quality gates.
  Keep the earlier intermittent committed-delivery failure unresolved; its
  diagnostics remain. HEAD remains `95b0e726a`; all continuation work is uncommitted.

### Earlier checkpoints — historical, superseded by the latest checkpoint above

**2026-10-10 validation resumed after host contention:** the user reported high
computer contention and requested a retry. Tool/Mix execution now completes.
P2 API/Engine suites pass **107 tests / 2 properties** (23.9s); the
Executor/history-sync/Engine matrix passes **94 tests / 2 properties** (50.9s);
real Mattermost selected-agent and history-strategy full-flow passes **40 tests**
(54.9s). Local alias/nesting quality findings were fixed; latest `mix q` passes
(1,547 files / 19,060 modules/functions), as does `git diff --check`.
The live admission-session regression was strengthened to reject changed content,
foreign actors and unrelated session references after revocation, then passed
its focused rerun (1 test). P2 stays open: full after-gate-before-runtime completion
coverage awaits alignment with P4's protected fresh-history behavior.
The earlier Sandbox timeout did not recur; contention is plausible but not an
established root cause. No assertions/deadlines/config/dependencies changed for
the retry. `.31.15` now contains this validation checkpoint.

**Earlier checkpoint (2026-10-10):** P1 admission evidence is implemented and locally
closed as `.31.14`. P2 `.31.15` is in progress and **not validated**. Remaining steps
are `.31.16`–`.31.20`, wired linearly. No P3–P7 implementation yet.

- Last green **before P2 edits**: execution-history, private-concurrency and new
  admission-migration suites, 42 tests / 1 property, zero failures; `mix q` passed
  (1,547 files / 19,057 modules/functions). These results do not validate P2.
- P2 first combined run: 27 API-routing failures from existing spies matching the
  old action, plus one Sandbox ownership timeout. The spies were updated to
  `:admit_execution`; the rerun has not completed successfully.
- Validation then stalled across Context Mode and native shell. Even
  `mix run --no-start --no-compile --no-deps-check` hung; independent Elixir
  diagnostics also stalled during startup. Cause unestablished, not a demonstrated
  dependency incompatibility. Do not fix dependencies on that evidence.
- A background `MIX_DEBUG=1 mix test test/zaq/agent/api_test.exs --max-cases 4`
  reached CLI/loadconfig/deps.loadpaths/archive.check but never tests before the
  assistant terminated its own PID 88300. Tool notification confirmed SIGTERM.
  Shutdown registry/Repo errors in other timed-out runs are not proven root cause.
- The attempted `.31.15` progress comment timed out; verify whether it persisted.
  Repository HEAD remains `95b0e726a`, 39 stashes remain, and no commit/push occurred.

- Branch `feature/issue-768-history-b-execution`, HEAD `95b0e726a`; dirty, entirely
  uncommitted continuation; 39 stashes retained. No publication or merge performed.
- `.31.8` registry removal, `.31.9` execution identity and `.31.7` live handoff are
  closed after their issue checks (the user supplied the pending `mix q` evidence).
  `.31.11`'s upstream dependency update and Zoi compatibility now pass their native
  regressions and quality gate. `.31.10` remains in progress; these local
  checkpoints are not full #768 acceptance.
- Latest isolated steering run: **10 tests, zero failures**, seed 625, normal
  schedulers. Includes actual native `idle`/sealed-queue `closed`, consumer lag and
  removal while waiting. Last green preceded only the new test's alias-only fix.
- Combined ten-file Agent/Pipeline/Engine/receipt/concurrency/migration matrix:
  **230 tests / 9 properties, zero failures**, seed 625. Not rerun after adding the
  extra sealed-queue test; it changes no production behavior.
- Current-tree `mix q` passes with normal schedulers: exit 0/no subprocess error,
  1,544 files / 19,013 modules/functions, no issues and docs generated. Earlier
  ExDNA timeouts were not waived or counted as successes.
- Latest expanded preservation matrix after the upstream update: **2,357 tests /
  59 properties / 17 doctests, zero failures**, seed 625, four ExUnit cases, normal
  schedulers. The ordered native long stream, 101-run default eviction/archive
  authorization/teardown and HTTP-tool completion now pass. Alias/native/HTTP/nested
  repeat seed 2026 passes **38 tests / 2 properties**.
- A five-file repeat including all history-strategy cases, seed 0, ran **75 tests /
  2 properties with one failure**: Shared owner-followup did not produce the
  committed-delivery notification. Those active-update cases pass unchanged in
  isolation (**10 tests**, seed 0). Keep this intermittent failure tracked in
  `.31.10`; no causal relationship to native ordering or `.31.5` is established.
- Manager/StreamEvents/observation suites: **92 tests / 6 properties, zero failures**.
  Suspended native shutdown regression passes. Preserve unskipped regressions;
  remaining real busy-admission closure and final preservation/acceptance are open.
- Independent pre-existing `.31.5` refreshed-Shared concurrent first-model timeout
  remains unresolved; no causal diagnosis or deployed selected-agent fix is claimed.
- The user identified merged upstream `jido_ai` PR #370 and authorized updates:
  `jido_ai` `970575a89631` (2.4.0), `jido` 2.4.0, Zoi 0.18.11. The new dedicated
  worker EmitEvent preserves native FIFO order. Generic Emit remains unchanged.
  After the first compile stopped at the removed Zoi Default wrapper, the user
  separately approved removing that OpaqueAliases clause; existing traversal and
  scope checks are preserved. See the [diagnostic](../../operations/native-event-ordering.md).
  Human UX/behavior, browser E2E, review/coverage, final precommit and publication
  gates remain separate.

## 3. Active files

Admission-change files added/edited in this continuation (other WIP below predates it):

| File | State | Current admission work |
| --- | --- | --- |
| `priv/repo/migrations/20261010100852_add_execution_admission_timestamp.exs` | Untracked | Nullable authorization timestamp; generated with Mix. |
| `test/zaq/engine/conversations/execution_admission_migration_test.exs` | Untracked | Rollback/reapply preserves private rows without fabricating acceptance. |
| `lib/zaq/engine/conversations/execution_record.ex` | Modified | `admitted_at`, deliberately excluded from ordinary cast attrs. |
| `lib/zaq/engine/conversations/execution_lifecycle.ex` | Modified | Acceptance write and provisional denial closure. |
| `lib/zaq/engine/conversations.ex` | Modified | Locked `admit_execution/3` with capability/content/Person validation. |
| `lib/zaq/engine/conversations/{execution_history,transcript_history}.ex` | Modified | Shared projection with trusted effective-access denial; ordinary reads still sanitize denial. |
| `lib/zaq/engine/api.ex` | Modified | Confidential admission operation. |
| `test/zaq/engine/conversations/execution_history_test.exs` | Modified | Admission/replay/forgery/boundary tests plus unvalidated live-session grant-loss test. |
| `lib/zaq/agent/{api,executor,history_sync}.ex` | Modified, P2 unvalidated | Session begins before gate; accepted projection is carried in calling process's scoped session data, keyed by exact binding, validated identity and content. Executor reuses it or gates standalone. |
| `test/zaq/agent/api_test.exs` | Modified, P2 unvalidated | Existing spies now recognize `:admit_execution`. |
| `/Users/julien/.opencode/plan/768-admission-time-authorization.md` | Outside repository | Approved seven-step implementation plan. |

All states below are against the current HEAD; untracked files must be included
when eventually committing. Pre-existing queue/revocation/diagnostic WIP is preserved.

| File | State | Role |
| --- | --- | --- |
| `config/test.exs` | Modified, prior WIP | Test queue setting; preserve and validate |
| `docs/README.md` | Modified, prior WIP | Diagnostic navigation |
| `docs/exec-plans/active/2026-10-08-handoff-history-b.md` | Modified | Current checkpoint plus preserved historical evidence |
| `docs/services/agent.md` | Modified | Native authority, inspection and live handoff contract |
| `docs/services/engine.md` | Modified | Exact execution/capability and recovery-root contract |
| `docs/operations/late-steering-sealing-race.md` | **Untracked**, prior WIP extended | Historical diagnosis and local resolution limits |
| `docs/operations/native-event-ordering.md` | **Untracked** | Native dispatch ordering evidence and dependency decision |
| `mix.exs`, `mix.lock` | Modified | Approved upstream Jido/Zoi update and resolved transitive dependencies |
| `lib/zaq/agent/api.ex` | Modified | Native inspection, live reservation orchestration, trusted fresh binding and finalization |
| `lib/zaq/agent/executor.ex` | Modified | Exact execution refs, reservation adoption and opt-in busy handoff |
| `lib/zaq/agent/factory.ex` | Modified | Exact native request lifecycle and inspection overlay |
| `lib/zaq/agent/history_lifecycle.ex` | Modified | FIFO waiter IDs/deadlines/monitors and lease transitions |
| `lib/zaq/agent/history_sync.ex` | Modified | Process/session-bound reservation and normal admission adoption |
| `lib/zaq/agent/opaque_aliases.ex` | Modified | Removed obsolete Zoi Default wrapper clause only |
| `lib/zaq/agent/pipeline.ex` | Modified | Internal handoff result propagation without public metadata |
| `lib/zaq/agent/request_control.ex` | Modified | Authorized targeting, receipt queue/rejection and definitive refusal disposition |
| `lib/zaq/agent/request_registry.ex` | Deleted | Obsolete parallel lifecycle registry removed |
| `lib/zaq/agent/server_manager.ex` | Modified | Protected immutable observations, removal fences and reservation ownership |
| `lib/zaq/agent/stream_events.ex` | Modified | Retained presentation and execution-specific consumption refs |
| `lib/zaq/agent/supervisor.ex` | Modified | Registry child removed |
| `lib/zaq/engine/api.ex` | Modified | Confidential exact-execution and followup dispatch |
| `lib/zaq/engine/conversations.ex` | Modified | Admission bindings, explicit selection, locked preparation/finalization |
| `lib/zaq/engine/conversations/execution_lifecycle.ex` | Modified | Exact records, immutable recovery linkage and queue dispositions |
| `lib/zaq/engine/conversations/execution_record.ex` | Modified | Recovery association, constraints and immutable identity |
| `lib/zaq/engine/conversations/message.ex` | Modified | Public struct type for valid documented specs |
| `lib/zaq/engine/incoming_message_router.ex` | Modified | Execution ID in canonical binding |
| `priv/repo/migrations/20261009000000_add_execution_followup_identity.exs` | **Untracked** | Additive uniqueness/preflight and evidence-preserving rollback |
| `test/zaq/agent/api_test.exs` | Modified | Migrated registry fixtures |
| `test/zaq/agent/executor_integration_test.exs` | Modified | Migrated native execution fixtures |
| `test/zaq/agent/history_context_sync_test.exs` | Modified | Expiry, death, FIFO, adoption, abort/replacement/removal and low-level refusal |
| `test/zaq/agent/request_registry_test.exs` | Deleted | Replaced by observation tests |
| `test/zaq/agent/request_inspection_test.exs` | **Untracked** | Actual ordered >2,000-event stream, default 100-request eviction, teardown, unavailable shutdown and retained inspection |
| `test/zaq/agent/request_observation_test.exs` | **Untracked** | Ownership, retained fields, removal and terminal properties |
| `test/zaq/agent/opaque_aliases_test.exs` | Modified | Defaulted signed-handle expansion and scope-isolation property |
| `test/zaq/agent/server_manager_test.exs` | Modified | Real supervised initialization and complete lifecycle state fixtures |
| `test/zaq/channels/history_strategy_full_flow_test.exs` | Modified, prior WIP extended | Real steering/closure/sealed queue/removal regressions |
| `test/zaq/channels/mattermost_shared_history_integration_test.exs` | Modified, prior WIP | Observation fixture migration and preserved revocation assertions |
| `test/zaq/engine/conversations/execution_history_test.exs` | Modified | Fresh root/capability, immutable receipt, replay and terminal-before-queue cases |
| `test/zaq/engine/conversations/execution_input_receipts_migration_test.exs` | Modified | Dependency-aware migration roundtrip |
| `test/zaq/engine/conversations/execution_record_test.exs` | Modified | Stronger one-root capability property |
| `test/zaq/engine/conversations/private_execution_concurrency_test.exs` | Modified | Independent-connection one-capability preparation |
| `test/zaq/engine/conversations/execution_followup_migration_test.exs` | **Untracked** | Empty/populated upgrades, conflict preflight and rollback refusal |

## 4. Changes Made

2026-10-10: Engine now distinguishes provisional persisted input from authorized
execution using `admitted_at`. Admission uses existing history permissions; denied
never-admitted roots fail without deleting factual input, while denied replays leave
accepted executions unchanged. The initial four new regressions failed first, then
the expanded P1 matrix passed. P2 moves the API completion session before permission
admission and caches only the Engine result for that live calling process; a raw
reference supplied from outside that process has no cached authority. Session state
is removed in `after`. This P2 design is currently unvalidated and must be reviewed
against exact-binding/content propagation and attachment normalization.

- Jido, not presentation status, now owns acceptance. ServerManager retains
  sanitized inspection/immutable targeting and removal evidence; RequestRegistry
  and its supervisor child are deleted. Existing stream reduction supplements
  bounded native traces rather than treating a later strategy snapshot as history.
- Canonical bindings carry execution IDs through history/control/native refs and
  finalization. Input-only selection refuses ambiguity. One new root links to an
  unchanged rejected receipt with a fresh private capability; one caller receives
  execution authority, and only that root owns answer/accounting/trace output.
- Definitive `idle`/`closed` or finalized-before-queue incoming dispositions wait
  on the same runtime's FIFO lease before confidential preparation. The normal
  pipeline adopts it once, revalidates authorization and uses normal finalization.
  The handoff is bounded to 60 seconds or a shorter incoming deadline. Dead/expired
  callers cannot acquire late leases, and queued/just-granted inputs are removal-fenced.
- Low-level steer/inject retain refusal, with no automatic recovery; generic
  errors/overflow/mismatch/consumption do not gain a recovery disposition. Local
  session/reservation details are stripped from API return opts and never stored
  in public outgoing metadata. No provider-specific retry branch was added.
- Reuse evidence: extended existing Conversations transactions, RequestControl,
  ServerManager/HistorySync leases and Pipeline/Executor/Factory/finalization. The
  reservation/continuation is local-only lifecycle orchestration, not a new Action,
  tool or scheduler. Credo fixes extracted small private helpers, not new operations.
- The user approved the focused plan at
  `/Users/julien/.opencode/plan/768-request-lifecycle-race.md` and authorized proceeding;
  the earlier investigation-only stop is historical, not the current authorization.
- Preservation extensions fix terminal flush fields, terminal native acceptance
  and unavailable-runtime shutdown safety in existing owners. Native ordering is
  fixed by the upstream dependency update, not a new ZAQ path. Zoi compatibility
  removes one old clause and adds a property; no signing/default semantics change.

## 5. Failed attempts

2026-10-10: P1 `mix q` initially reported a one-clause `with` and excessive nesting;
local helper/case changes fixed both and q passed before P2. After P2, the first
combined API/Engine run hit stale router fixtures plus a Sandbox timeout. Updating
fixtures is not proof the suite passes. Subsequent Context Mode calls timed out even
for process diagnostics; native-shell Mix calls also stalled before useful test
output. No deadlines/assertions were increased. Do not repeatedly rerun whole suites
until startup/tool execution is healthy. The explicit native HTTP-tool cancellation
regression remains unchanged in its original file; its approved relocation to a
documented reproducer is P6, not yet performed.

- `bw comments add` was invalid; correct command is `bw comment <id> <text>`.
- A combined multi-file patch failed exact-text verification; none of that patch
  applied. Retry against current formatted text rather than assuming partial writes.
- Serena returned an empty Elixir symbol overview; bounded reads were used. A
  dependency search guessed the wrong directory; actual pending-input code lives
  under `deps/jido_ai/lib/jido_ai/reasoning/react/`.
- `%Message{}` in specs triggered Credo; `Message.t()` was missing. Added the public
  type and used it. Initial quality checks also caught nesting/alias issues, fixed
  through private helpers and a normal alias.
- A consumed-terminal queue change returned `:input_consumed` where the existing
  low-level contract required `:terminal_request`. The unchanged test failed; the
  original terminal result was restored, without enabling recovery for consumed input.
- CPU-constrained real-flow retries missed initial barriers during heavy host load.
  Normal scheduler allocation passed all 10 cases with unchanged assertions/timeouts.
- Do not mistake subprocess exit 0 after SIGTERM for successful validation: earlier
  `spawnSync` attempts also reported `ETIMEDOUT`. Later runners print both status
  and subprocess errors. Latest `mix q` failure is its internal ExDNA timeout,
  not a completed quality pass. No timeout/check configuration was changed.
- Earlier Git access `Operation not permitted` was resolved by OpenChamber restart;
  no Git metadata repair/reset was performed. Preserve all prior WIP and stashes.

## 6. Next step

**Superseding ready next action:** continue P2's real accepted-input execution
coverage and remaining approved P3–P7 work. Startup is no longer blocked. Preserve
the recorded Sandbox failure for investigation if it recurs; do not restart the
already successful retry merely to obtain more passing evidence. The earlier
startup-diagnostic instruction below is historical.

**Current next action — Ready:** diagnose the stalled Mix/tool execution environment
with a bounded startup diagnostic, then run the P2 API and Engine suites. Use the
existing normal-scheduler/four-case setup; investigate the recorded Sandbox timeout
rather than accepting a lucky rerun. Do not terminate unrelated dev servers.

Then finish P2's real after-gate-before-runtime regression, inspect session propagation
and run `mix q`. Proceed through `.31.16`–`.31.20` in the approved plan. Keep old
membership fences until their planned coordinated replacement; do not claim graceful
retirement already works. Human behavior/E2E/final precommit gates remain pending.
No commit/publication, new dependency fix, weakened assertion or restored strict
membership-cancellation requirement is authorized by this checkpoint.

The older next-step list below is historical where it conflicts with this update.

1. **Ready:** rerun current-tree `mix q` with normal schedulers through Context Mode
   when host contention permits; inspect both exit status and subprocess errors.
   Fix real findings, but do not weaken ExDNA or kill unrelated user processes. Keep
   `.31.7` open until its current-tree issue gate succeeds.
2. **Ready after that:** reconcile `.31.7`, then start `.31.10` and verify actual
   >2,000-event native streams, native request retention/eviction and runtime
   teardown, historical-request isolation, real busy-admission closure, caller and
   permission failures, media/draft/routing preservation, populated migrations and
   the remaining approved handoff failure cases. Run applicable preservation suites.
3. **Ready:** diagnose independent `.31.5` without conflating it with sealing or
   claiming that overloaded isolated retries establish its cause; retain original
   timeouts/assertions. Repeat complete acceptance and update Beadwork evidence.
4. **Blocked on user at the later gate:** obtain separate behavior/UX approval in
   `.32` before new consolidated browser E2E (`.13.2`), then review, fresh coverage,
   final `mix precommit` and final approval. Publication/merge need separate authority.

Do not reset/reassign historical data, rewrite drafts, discard WIP/stashes, promote
rejected receipts, retry ambiguous native starts, publish/merge implicitly, weaken
assertions, self-approve UX or claim final acceptance. The historical checkpoints
below are retained for evidence and do not override this current state.

### Steering follow-up — 2026-10-09 (historical checkpoint)

The focused lifecycle/recovery implementation is now authorized and in progress.
Registry removal (`.31.8`) and explicitly addressed recovery roots (`.31.9`) passed
their isolated matrices and quality checks. The live handoff (`.31.7`) passes real
discovery-to-steer closure and removal-while-waiting regressions; rejected receipts
retain their identity/status, and one fresh root runs through normal execution.
FIFO waiters are bounded, monitored and removal-fenced; normal admission adopts
the reservation inside the existing completion session. Broader preservation and
current-tree quality validation remain open. Changes are uncommitted; no publication,
deployment, human approval, browser E2E, final coverage/precommit or merge is claimed.
`.31.5` remains an independent blocker. Durable progress is in Beadwork.

### Historical investigation checkpoint (superseded)

Investigation was **paused at the user's request**. The observed-problem brief is
[Late-steering sealing race](../../operations/late-steering-sealing-race.md).
No retry design or persistence change was approved or implemented.

- Local commit `95b0e726a` fixes `zaq-emb.31.6`'s request lookup across all four
  emitted active statuses. Scope, principal, configured-agent, exact-PID ownership,
  terminal and removal checks remain unchanged. No push or deployed fix is claimed.
- Six production-path cases pass with real registered sleep tools, provider ingress,
  Engine authorization/receipts, Jido input consumption, model requests and confirmed
  Mattermost delivery. The first reproduces the 10-second then 5-second sleeps;
  active Spanish corrections yield one `Hola` answer and one owning root, with
  exactly two tool calls and three model calls. Other cases cover the second sleep,
  reasoning/text streaming, silent next-model waiting and an ordinary completed
  follow-up. Only external provider/model HTTP is replaced.
- Commit validation: `mix q`, commit hooks and diff checks passed. The five-file
  registry, stream-events, API, Executor and history-strategy preservation run at
  seed 625 passed **198 tests / 9 properties / 6 doctests**.
- **New unresolved failure, `zaq-emb.31.7`:** delaying only the actual stream consumer
  lets native Jido complete while the registry still reports `:tool_completed`.
  A late correction queues a child receipt but receives `{:rejected, :idle}`;
  that receipt becomes `unconsumed` and no follow-up model request starts. The
  isolated `steering_phase:sealing_race` regression fails deterministically (one
  test / one failure). Preserve this uncommitted regression and its assertions.
  The latest five-file run at seed 625 has **199 tests / 9 properties / 6 doctests,
  one failure**, exactly this late-follow-up regression; current-tree `mix q` passes.
  Safe recovery must retain immutable receipt/root ownership and canonical UUIDs;
  blindly treating rejection as `:not_active` cannot satisfy the current contract.
- The pre-existing queue/revocation/handoff WIP remains preserved. The strategy
  suite now also has the sealing-race regression WIP; its previously green commit
  validation must not be represented as a green current-tree acceptance run.
  Durable next work lives in Beadwork. `zaq-emb.31.5` remains independently unresolved.
  No human approval, browser E2E, final `mix precommit`, publication or merge gate
  has been completed by this steering fix.

### Renewed implementation evidence — 2026-10-08

The approved failure-inventory fixes are implemented and locally committed.
This is renewed **pre-UX integration evidence**, not human approval, browser E2E,
final review/coverage, final `mix precommit`, publication or merge.

> **Current acceptance remains blocked.** The final expanded matrix reproduced
> a concurrency failure. `zaq-emb.31.5` is in progress; `zaq-emb.31` and the
> separate human gate `zaq-emb.32` must not be closed from the earlier green runs.

### Current stack and fixes

- PR A remains https://github.com/www-zaq-ai/zaq/pull/835. Its local branch now
  includes `628be8397` and `fad3b046f`; neither was pushed. The owning-A fixes
  were merged locally into B at `20ac23d7a`; its latest steering tip is `95b0e726a`.
- Shared first contact uses raw/adapter-matching, connector-scoped
  Mattermost/Telegram sender evidence and existing provider grant provenance.
  Threads inherit parent access. Replays/later posts cannot restore removed
  grants. Complete snapshots retain room-wide authority; targeted evidence
  fences only its subjects. Legacy unknown scope remains conservative.
- `bcd667bfd`: Replicated admission selects the exact recipient transcript and
  Person container rather than the first email-thread owner's container. Public
  threading, canonical IDs, historical ownership and accepted delivery remain
  unchanged. Concurrent participant and recipient-only assertions now execute.
- `854a8e6d9`: runtime measurements persist privately for success/failure,
  preserving zero versus unavailable and authoritative token accounting.
  Native model lifecycle evidence includes tool-only turns.
- `17ef98ad9`: the existing confidential administrator message-info operation
  projects only the exact completed root after placement/ownership checks.
  Public rows stay sanitized; legacy telemetry remains a fallback.
- `09845927e`: repeated/late native tool starts preserve real arguments and
  completed evidence; repeated completions do not duplicate tool trace rows.
- All 27 real-flow acceptance cases remain. Newly reachable fixture defects
  were corrected without weakening assertions: accepted `auto-replied` evidence
  for passive email, the existing humanized tool label for modal expansion, and
  revocation of actual ingress-created provider access rather than only a seeded
  manual grant. Modal assertions now compare exact persisted measures and real
  tool arguments/results after fresh reloads.
- Both worktrees preserve unrelated work and all 39 stashes. No historical
  records, populated databases, original drafts or published branch history were
  reset, reassigned or discarded.

### Renewed validation

| Scope | Result |
| --- | --- |
| Owning A membership/normalization/ingress/integration suites, seed 104729 | 257 tests / 6 properties, zero failures |
| Expanded nine-file strategy, removal, delivery, credentials, modal and private-execution matrix, seeds 0/625/104729, before final A scope follow-up | 173 tests / 6 properties per run, zero failures |
| Latest ten-file matrix, seed 625, after all A scope fixes and test queue adjustment | 180 tests / 8 properties, one failure: refreshed-Shared concurrent Bob first model request did not arrive within the unchanged five-second assertion |
| Agent, canonical Conversations and runtime-removal preservation, seed 625 | 1,994 tests / 58 properties / 17 doctests, zero failures; 21 existing exclusions |
| Channels plus 78 related Engine/Accounts/Permissions/People suites and BO history, seed 625 | 2,355 tests / 60 properties, zero failures |
| Fresh migration chain plus canonical storage, ingress, membership, strategies and persisted modals, seed 104729 | 328 tests / 17 properties, zero failures |

Counts overlap; do not sum them as unique coverage. Normal schedulers and
`--max-cases 4` were used for broad tests. Standard integration/ParadeDB/browser
exclusions were not changed. The fresh database used test partition `_r1008fix`,
was verified absent before creation, bootstrapped with `mix db.extensions`, and
was dropped afterward. Native search was used because `pg_search` is unavailable.
Empty/populated receipt rollback/reapply and populated rollback refusal passed;
the working database was untouched. Issue-level `mix q`, diff checks and commit
hooks passed without bypasses.

Earlier committed-delivery waits failed intermittently despite green matrix,
preservation and fresh-database runs. A subsequent final matrix reproduced the
Replicated wait, so readiness was withdrawn again rather than relying on retries.
Temporary native call/return/exception tracing proved both generations completed
and SMTP confirmed both transports, but one history capture raised an actual
`DBConnection.ConnectionError` (`:queue_timeout`) on the single shared Sandbox
connection after 136 ms. That answer correctly had no confirmed placement;
transport success was retained with history capture reported unavailable.

The current **uncommitted** `config/test.exs` adjustment raises only the shared
Sandbox queue target from the default 50 ms to 1,000 ms. Production configuration,
query deadlines and five-second assertions are unchanged. Sixteen consecutive
isolated runs of the two concurrent-People cases then passed (32 case executions).
The broader matrix subsequently reproduced a different surface: refreshed-Shared
Bob's first model request timed out after visible formulation status. This also
occurred once during the first queue-adjustment repeat attempt. Its root cause
remains unproven. A focused diagnostic found no extra/misclassified initial model
request and both private roots still pending; ten subsequent isolated retries
passed but do not erase the failure. Do not label it a resolved infrastructure
flake or restore approval readiness. All temporary diagnostic tracing/printing
was removed at that checkpoint; the later steering regression WIP is recorded
above. At that checkpoint, `mix q` and
`git diff --check` pass.
Unrelated `zaq-mcw`/`zaq-e8q` remain open and are not assumed to explain this failure.

Pre-steering uncommitted work comprised this handoff, the test-only queue adjustment,
and the two stronger actual-provider-revocation fixtures in the Shared integration
suite. Preserve these changes; do not commit them as fully validated acceptance.

### Next work and blocked gate

First resolve the steering sealing/retry contract in `zaq-emb.31.7`, preserving
the failing regression. Then diagnose the refreshed-Shared concurrent first-model failure in
`zaq-emb.31.5`, retaining all assertions and timeouts. Distinguish absent transport
from runtime/admission/before-model waits using the real request and exact
consumer/runtime state. The diagnostic did not support prompt misclassification.
Validate the queue adjustment
and revocation fixtures, repeat the complete matrix and affected preservation
suites, then update `zaq-emb.31` with the actual final result.

Only after that, obtain **separate explicit PR B behavior/UX approval** in
`zaq-emb.32`, covering
unseeded Shared/Direct/Replicated entry, Person-bound steering/concurrency,
recipient isolation, removal/replay fences, truthful completion/delivery, and
persisted private Message information. Only then author/run consolidated browser
E2E (`zaq-emb.13.2`). Review, fresh coverage and final `mix precommit` still precede
final implementation approval. Publication and merge require separate authority.
PR A's cancelled Firefox/aggregate CI and token-blocked rerun remain its separate
validation gate; local A fixes have not updated the published PR.

### Historical readiness withdrawal

> **Approval readiness withdrawn earlier on 2026-10-08.** The historical validation below
> did not establish unseeded Shared sender authorization or persisted private
> execution telemetry in the Message information modal. `zaq-emb.31` is reopened;
> `zaq-emb.32` is open and blocked pending renewed integration evidence. The
> tests-first failure inventory is tracked in `zaq-emb.31.1`–`.3`. No production
> fixes, PR B publication, merge or human approval are implied by this handoff.

### Historical goal

Complete #768's second outcome: Person-bound agents consume authorized durable
history and complete reliably without duplicate context, lost inputs, leaked
private execution data or false delivery confirmation. The user authorized local
implementation and validated commits through the human approval step, not PR B
publication or merge.

### Historical State Before Acceptance Was Reopened

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

### Historical active files

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

### Historical changes made

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

### Historical failed attempts

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

### Historical next step — superseded by the renewed gate above

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

### Session log

- 2026-10-09: resumed authorized implementation, recorded A/B checkpoints,
  implemented the bounded live handoff and validated 10 real steering cases plus
  230 tests/9 properties. Kept C open because the final quality retry timed out
  inside ExDNA; D, independent concurrency and final acceptance remain open.
  Verified dirty Git inventory and 39 stashes; no commit, push or merge.
