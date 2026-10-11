# PR B history execution — local implementation review

- Branch: `feature/issue-768-history-b-execution`, HEAD `95b0e726a` plus staged
  continuation and unstaged consolidated E2E changes. No published PR B exists.
- Linked issue: [#768](https://github.com/www-zaq-ai/zaq/issues/768).
- Comparison base: PR A `fad3b046fd3197320c9b3628075068e84f7fb11e`
  ([#835](https://github.com/www-zaq-ai/zaq/pull/835)); no upstream publication.
- Date: 2026-10-10. **Local implementation review approved for coverage with an
  explicitly deferred historical finding; not final acceptance or publication.**

**Coverage update, 2026-10-11:** successful human fresh coverage is now accepted
(10,593 tests / 236 properties / 48 doctests, zero failures, 850.2s).
[Per-file results](history-b-coverage-results.md) record the 13-file gap assessment,
seven test-file additions and explicit remaining coverage exceptions. Added tests
pass 284 tests / 4 properties under targeted coverage; `mix q` passes. Review
corrected draft fixture assumptions rather than changing production behavior or
weakening prior assertions. Admission inheritance uses one session starting before
revocation; the hook test exercises the actual registry; denied Executor admission
uses real Engine/permission paths. No new blocking code finding; final precommit
now passes after these additions (exit 0, no timeout, 284 stale-selected tests /
4 properties, zero failures, 19,120 modules/functions without findings). Final
human acceptance remains pending. Older coverage-blocked notes below
are historical evidence, superseded by this update.

## A — Inline review comments

No substantiated new blocking code defect in the inspected changed production paths.
One documentation correction was applied: `docs/services/message-lifecycle.md:42`
still named the deleted `RequestRegistry`. It now names `RequestControl` and
explicitly assigns native acceptance/lifecycle to Jido. No production code changed
during review.

## B — General review comments

### Medium — Historical intermittent committed-delivery failure remains unresolved

**Problem:** a previous five-file seed-0 run failed Shared own-author steering
at the unchanged five-second committed-delivery assertion after real model
continuation. The historical observation was retained in `zaq-emb.31.10` and the
handoff. Its cause was not captured conclusively; neither native event ordering,
HTTP-pool wakeups nor SQL Sandbox contention is established as its explanation.

**Current evidence:** the same five-file scope now passes 75 tests / 2 properties
on three separate seed-0 runs (81.3s, 101.6s, 82.2s), with the failure-only
`DeliveryDiagnostics` collector and original assertions intact. The combined
browser/native history matrix passes 83 tests (318.7s). A wider seed-0 native
preservation run passes 3,490 tests / 79 properties / 17 doctests (343.8s).
Counts overlap. These successes do not establish a causal fix for the prior failure.

**Why it matters:** generation success is not provider-confirmed committed history.
Closing acceptance on green repeats alone would conceal the unresolved reliability
observation and contradict the agreed validation contract.

**Recommendation:** keep `.31.10` open. Continue diagnosis with the existing bounded
pre-teardown native-call/SQL/Finch/process/execution/confirmation/placement evidence
when the failure is reproducible, or obtain an explicit human decision to carry
this observation as a separate unresolved follow-up. Do not weaken assertions,
add retries, silently equate distinct defects or claim the historical failure fixed.

**Disposition:** Julien explicitly selected **"Carry unresolved follow-up"** in
this session on 2026-10-10. The unresolved observation is now independently tracked
in **open `zaq-1wb`**, preserving its evidence, diagnostics and five-second assertion.
It is nonblocking for the current review/coverage/final-precommit sequence, not
fixed or causally diagnosed. Any new failure still blocks completion. `.31.10`
remains open until its remaining integrated validation work is completed.

## C — Recap

- **Verdict: approve for the local coverage gate with the acknowledged deferred
  risk above.** This is implementation review, not final human acceptance, an
  external published PR review or a clean final-precommit claim.
- The inspected core preserves admission-time actor/content/binding ownership,
  process-local admission evidence, native lifecycle authority, exact-PID
  retirement, rejected receipt identity and one linked recovery. New browser
  journeys exercise real ingress, native tools, provider delivery, persisted
  telemetry/reloads and ordinary BO authentication/authorization.
- Reuse evidence: Engine Conversations/ExecutionLifecycle own admission and
  recovery; HistorySync/ServerManager/HistoryLifecycle own local runtime mechanics;
  NodeRouter events remain the service seam. New browser orchestration is
  test-local, reuses the existing production-path and ephemeral-Endpoint patterns,
  and adds neither a business Action nor a production test endpoint.
- Findings: 0 high, 1 medium deferred, 1 low documentation finding corrected;
  1 resolved inline documentation observation, 1 deferred general finding.
- Issue context: full #768 body and all four comments read; PR A metadata verified.
  Historical foundation PR references in those comments do not change the current
  two-outcome delivery contract. No further related issue was identified there.
- Scope inspected: changed production hunks and relevant definitions in Agent Api, Executor,
  RequestControl, HistorySync, HistoryLifecycle, ServerManager, Factory,
  RequestTransformer and Engine Conversations/ExecutionLifecycle; new browser
  support and affected full-flow fixtures; remaining Agent history loader/idle,
  pipeline/supervisor/opaque-schema compatibility, Engine Api authorization,
  membership reconciliation, ChannelHistoryAdmin private projection, immutable
  execution schema, canonical transcript reads/reuse, root-only accounting,
  inert persisted-removal adapter and incoming binding paths. Reviewed all three
  new migration constraints/rollback guards and dependency/runtime-config changes.
  Test review checked new risk scenarios and removed assertions: deleted registry
  tests concern the removed duplicate lifecycle authority; changed manager init
  fixtures use the current callback contract, not reduced runtime expectations.
  Native deadlines and meaningful delivery expectations remain unchanged.
  The inventory is 88 tracked changed files plus untracked browser/review support;
  binary demo captures and manual repros are evidence, not automated regressions.
  Review uses bounded risk-based inspection, not a claim of line-by-line proof.
- Complementary current Engine BO/membership/dispatch/history/removal/rating
  matrix: **146 tests / 3 properties**, zero failures, seed 0 (49.0s). Changed
  documentation local-path links resolve. Lifecycle navigation now matches the
  removed RequestRegistry and native Jido ownership.
- Positive evidence: 21 consolidated browser cases across three engines, each at
  mobile/desktop widths, pass in the 83-test matrix. Late rejected-receipt recovery
  after access loss retains both answers and retires the exact incarnation.
  Browser login precedes live model holds, which remain below the native timeout.
- Human behavior approval: Julien explicitly confirmed after personal dev testing;
  `.32` closed and `.13.2` completed. This is not final review approval or Git
  authorization. Upstream stream timeout and independent explicit cancellation
  defects remain deferred; upstream timeout report publication failed with 403.
- Numerical coverage has **no successful fresh report**. Final `mix precommit` has **not** run.
  No commit, push or merge performed.
  Update: the first fresh coverage attempt failed two tests and then timed out
  during reporting/teardown at 600 seconds; its report was not accepted. The new
  test-only fixes in `zaq-0vo` and `zaq-m21` were reviewed: rejection sampling is
  replaced by valid bounded duplicate recipient inputs with a stronger reversal
  assertion; explicit manual sandbox mode restores the exact expected no-owner
  exception rather than weakening it to accept checkout exits. The original
  generator fails at independently reproduced seed 6258 / size 60. A real
  NodeRouter telemetry probe after 100 stopped shared owners produced 98 checkout
  exits and 2 OwnershipErrors; explicit manual mode produces OwnershipError.
  Affected property/BO/history-admin/strategy validation passes 73 tests /
  2 properties (70.9s), seed 6258, and `mix q` passes. No production code change.
  Approved to retry fresh coverage with bounded concurrency; any failure blocks.
  The retry `mix coveralls.json --max-cases 4 --seed 6258` also timed out:
  `timeoutMs=600000`, `elapsedMs=600368`, `error=spawnSync mix ETIMEDOUT`.
  It used the unchanged standard exclusions and produced no completed ExUnit
  summary or ExCoveralls completion. The timeout error invalidates its reported
  `status=0`; it is not a passing run. Logs include a ChatLive task still using a
  stopped sandbox owner's connection and an MCP transport initialization
  CaseClauseError, neither established as the timeout cause or a numbered test
  failure. Full output/metadata is indexed as **PR B coverage retry mix
  coveralls.json max-cases 4 seed 6258 full output and subprocess metadata**.
  No stale/generated JSON was consumed, `mix coverup` and final `mix precommit`
  have not run. Coverage remains blocked; no numerical coverage claim or final
  acceptance is made. The two test fixes retain their isolated validation but
  not a successful full coverage validation.
  Subsequent human evidence: Julien reports all `mix precommit` steps passed,
  with 19,117 modules/functions and no findings, plus 48 doctests / 236 properties /
  10,593 tests, zero failures, one skipped and 122 excluded (849.0s). This is
  accepted as human-reported quality/test evidence, not an agent-run command or
  numerical coverage result. The alias does not produce a coverage report; the
  numerical coverage gate remains pending successful completion or an explicit
  human deferral. No redundant precommit rerun, final acceptance or publication.
- Token usage: runtime per-review metrics unavailable. Estimated review-specific
  input ~45,000 tokens including tool schemas/diff windows; output ~1,100 tokens;
  total ~46,100. These are estimates, not measured session billing.
