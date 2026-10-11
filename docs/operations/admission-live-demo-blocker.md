# Admission-time behavior: preserved timeout and bounded live review

## Outcome

The original 2026-10-10 long-held walkthrough remains failed and preserved.
Its native stream timeout silently exhausted without terminating the parent
request. A separate **bounded live scenario passed** with a 92 ms external model
barrier: admitted input → revocation → new input denied → accepted answer
persisted/delivered → exact runtime retired. This does not fix the timeout.

`zaq-emb.31.21` now tracks the diagnosed upstream defect and publication blocker,
not a prerequisite to bounded `.31.20` validation, per the user's explicit deferral.
Upstream issue creation failed through both CLI and the configured GitHub
integration with HTTP 403 (`Resource not accessible by personal access token`).
The [report and suggested fix plan](jido-ai-stream-timeout-report.md) are saved;
**no upstream issue was created**. Julien subsequently tested the development
environment personally and explicitly approved behavior; `.32` is now closed.
The consolidated browser/native history matrix passes 83 tests, including 21
browser cases across three engines at mobile/desktop widths. No dependency fix,
final acceptance or Git publication occurred. The user stopped the original demo;
it has not been restarted, and stored failure evidence remains preserved.

## Environment and scope

- Branch `feature/issue-768-history-b-execution`, HEAD `95b0e726a`, uncommitted work.
- Local server `zaq_admission_demo@macbookpro`, HTTP port 4002.
- New branch-isolated database `zaq_test_e2e_feature_issue_768_history_b_execution`;
  separate build `_build/test-e2e`. Existing databases were not reset or seeded.
- The missing extension on the new database was installed through existing
  `mix db.extensions`; available vector 0.8.2 satisfies the migration. Optional
  `pg_search` is unavailable, using the supported native-search fallback.
- Manual fixture: `test/repro/admission_live_demo.exs`. Only external Mattermost
  HTTP and model responses are doubles. Real ingress, identity, permission,
  admission, runtime, persistence and BO paths are used. This is not a new E2E spec.
- Runtime reports Jido 2.4.0, Jido AI 2.4.0, ReqLLM 1.22.0.
- Embedded browser sign-in stalled; normal login succeeded in headed Chromium
  using the isolated demo account. No authentication bypass was used.

## Original failed sequence — preserved evidence

1. Send a local Mattermost mention. Its execution is `pending`, `admitted: true`,
   with read access granted and a real model HTTP request held at the external stub.
2. Display the transcript and provider-derived grant in the BO.
3. Apply the real Engine membership removal event (revision 2). Read access becomes
   false; the refreshed BO access dialog shows **No current grants**. The accepted
   execution remains pending, not forcibly cancelled.
4. Send another mention. Factual capture remains, but its execution becomes `failed`,
   `admitted: false`, with no answer. NodeRouter logs the expected unauthorized denial.
5. Release the held external model response. The original request does not complete.
   Its parent strategy remains `awaiting_llm` with a pending request, while the native
   worker strategy is `idle`, with `runtime_task: nil`, `run_id: nil`, `last_error: nil`.
   The manager retains its lease and one admission pin. No public answer is linked.

The model barrier was held for several minutes during login/navigation/RPC setup.
This exceeded the effective 75-second native stream deadline. A database-free
Runner comparison now independently reproduces silent exhaustion at an explicit
1-second stream deadline: only `request_started` and `llm_started`, no terminal
event, normal enumerable end after about 1,016 ms. Prompt release succeeds in
about 203 ms. The report explains the Runner/worker source path; the standalone
parent/worker harness was inconclusive and is not claimed as a completed regression.
Transient control-node RPC connections initially failed because the hostname resolves
to two LAN addresses; control-process-only loopback resolution made RPC reliable.

## Evidence

- [Running input](../exec-plans/active/admission-demo-01-running.png)
- [Revoked access while accepted input is pending](../exec-plans/active/admission-demo-02-revoked-pending.png)
- Local server log:
  `/private/var/folders/9p/mdzhcqxx7hs8bw_10vwjvfp00000gn/T/opencode/admission-live-demo.log`.
- Original message `912c0468-587e-45da-8fb8-7368da99a76b`;
  denied message `98080945-be45-417b-9f97-170a57619300`.
- Parent native request `01a125f3-d06c-7d5a-8da7-f453609fad2c`.
- Transcript URL:
  `http://localhost:4002/bo/channels/history/42674778-beab-4976-846c-27eff1d2cd06`.

## Separate bounded live result

`test/repro/bounded_admission_live_review.exs` creates a fresh isolated connector
and complete Person, uses real ingress/admission/membership removal and observes
the external provider's terminal update. It asserts admission and pending native
work before revocation, failed unadmitted new input with no answer, immutable
accepted admission/Person/reply linkage, persisted exact answer and exact-PID
retirement. Five-second assertions are unchanged. The original demo state is
compared before/after and remains unchanged; it was not reset or retried.

- Successful model barrier: **92 ms**. Accepted root completed; new input failed
  without admission; provider terminal update observed; exact runtime retired.
- Transcript: `05bd4630-e520-4265-8f00-3ae4d749b96e`.
- Accepted message: `c9988ec4-0d56-46d5-a581-7ad56a81c20d`.
- Denied message: `3792ef56-6bad-49ac-b63b-7cb783e552b3`.
- Browser: [completed answer](../exec-plans/active/admission-demo-03-bounded-completed.png)
  and [answer with No current grants](../exec-plans/active/admission-demo-04-bounded-no-grants.png).
- Current `mix q` passes; focused Mattermost/history and HTTP preservation suites
  pass **27 tests**, zero failures (63.7s). Passing runs do not resolve the earlier
  intermittent committed-delivery failure or deferred timeout/cancellation defects.

Manual fixture development initially exposed control/setup errors (source slicing,
RPC-linked process lifetime, reused agent names, incomplete Person resolution,
terminal edit versus provisional post, and answer ownership field selection).
These were fixture corrections, not production fixes; failed attempts are not
counted as passing scenarios. The manual fixture itself is not a consolidated
browser E2E spec or human approval. Subsequent approval and consolidated E2E are
recorded separately in the [handoff](../exec-plans/active/2026-10-08-handoff-history-b.md).

## Remaining boundary

Publish the saved report once upstream issue-write permission is available. Do not
change dependencies to fix this deferred defect. Human behavior approval and the
consolidated history E2E run are now recorded; finish the unresolved intermittent
delivery investigation, review/coverage and final `mix precommit`.
Commit/push/merge require separate authorization.
