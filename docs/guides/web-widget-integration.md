# Web widget integration handoff

This walkthrough targets shared web protocol version **1** on the `refactor/webbridge`
implementation for [ZAQ issue 830](https://github.com/www-zaq-ai/zaq/issues/830).
The protocol source is [`lib/zaq/channels/web/`](../../lib/zaq/channels/web/), not a
second widget schema. Pin the final reviewed ZAQ revision when installing the
adapter. [WebBridge protocol](../services/web-bridge.md#widget-runtime-construction) owns the
runtime, trust and delivery contract. BO's working consumer is
[`ChatLive`](../../lib/zaq_web/live/bo/communication/chat_live.ex).

## Install an adapter-owned runtime

Configure the widget provider in the host application's existing Channels map:

```elixir
web_widget: %{bridge: Zaq.Channels.WebBridge, runtime_builder: MyWidget.RuntimeBuilder}
```

`MyWidget.RuntimeBuilder.build(config, hooks)` returns
`{:ok, {state_spec_or_nil, listener_specs}}` or `{:error, reason}`. ZAQ starts and
stops these children through its existing supervisor. The builder can use its
own endpoint/listener modules; it does not need a compile-time dependency back
to ZAQ. `hooks` supplies constructor modules and a config-bound sink MFA.
The connector's persisted ID is the widget ID. Configure presentation/embedding
settings according to the [canonical runtime contract](../services/web-bridge.md#widget-runtime-construction).

The adapter installs its own routes, socket/session verification, embedding
protections and subscription authorization. No ZAQ widget route macro or use
of the BO LiveView socket is required. Bundle and serve styling locally.

## Invoke the published sink

The following is schematic adapter code. It assumes `hooks` came from the trusted
runtime builder, `verified_sender` was obtained from server-side parent-app
identity verification, and `authorized_topic` was selected by the adapter for
that verified session. Neither value comes unchecked from browser payloads.

```elixir
delivery_module = hooks.delivery
context_module = hooks.context
command_module = hooks.command
message_module = hooks.message

{:ok, delivery} = delivery_module.new(%{
  consumer: :widget,
  channel_config_id: hooks.widget_id,
  topic: authorized_topic,
  events: %{
    typing: "response.typing",
    message_create: "response.message.create",
    message_edit: "response.message.edit",
    message_step: "response.message.step",
    message_complete: "response.message.complete",
    message_failed: "response.message.failed",
    error: "response.error"
  }
})

{:ok, context} = context_module.new(nil,
  consumer: :widget,
  channel_config_id: hooks.widget_id,
  sender_id: verified_sender,
  delivery: delivery
)

{module, function, args} = hooks.sink_mfa
invoke = fn payload -> apply(module, function, args ++ [payload, [context: context]]) end

{:ok, init} = command_module.new(%{request_id: "init-1", type: :conversation_init})
readiness = invoke.(init)

{:ok, question} = message_module.new(%{
  request_id: "question-1",
  message_id: question_uuid,
  timestamp: DateTime.utc_now(),
  channel: "default",
  mode: :async,
  content: question_text,
  prompt_context: retained_parent_context
})
receipt = invoke.(question)
```

The adapter subscribes to its authorized pre-creation destination **before**
sending the question. Opening a widget creates no chat/history. Retain optional
parent context until the first actual question; do not send privileged prompt
inputs, fabricated People bearers or BO permission capabilities. Resume by
supplying the authorized `conversation_id`; it does not reseed context.
Validate any raw supplied resume ID before construction: shared optional identifier
normalization can yield nil for malformed values. Do not translate a malformed resume
request into a fresh-chat question; unknown valid IDs still fail closed in Engine.

Commands return a semantic Response directly. Async messages return
`{:ok, Response}` acceptance; synchronous messages return one terminal Response.
Errors before acceptance can return `{:error, reason}`. Encode responses according
to their semantic type and retain request/conversation/message correlation.
PubSub events are `{:web_response, adapter_event_name, response}`. They are already
public projections; do not inject BO traces or raw tool calls into wire output.

## Lifecycle walkthrough

| Adapter action | Observable behavior |
| --- | --- |
| Open → init | Readiness, `created: false`, no new conversation ID |
| First async question | Creation receipt with new conversation ID |
| Accepted async work | Typing active → assistant create → optional edits/steps |
| Streaming edit | Replace the full content snapshot; never append it as a delta |
| Completion/failure | Typing inactive → one correlated live terminal |
| Sync question | One terminal return, no duplicate terminal PubSub delivery |
| Sync timeout | Unknown outcome; no cancellation or automatic retry |
| Restore | Authorized shared history command with the existing conversation ID |
| Unknown/foreign/deleted resume | Denied; no replacement conversation |

The assistant's stable transport ID is not necessarily its persisted message ID.
Terminal payloads expose persisted assistant/user references separately. History
is the recovery interface after timeout, reconnect or owner loss; PubSub offers
no durable replay or exactly-once execution promise. See the
[WebBridge protocol](../services/web-bridge.md) for bounds, pagination and timeout settings.

## Conformance and external acceptance

Executable host references:

- [`widget_conformance_test.exs`](../../test/zaq/channels/web/widget_conformance_test.exs):
  config-bound sink, real role dispatch, deterministic external LLM HTTP fixture,
  sync/async completion and authorized canonical history.
- [`runtime_test.exs`](../../test/zaq/channels/web/runtime_test.exs): host builder,
  startup/failure, updates, teardown, isolated connectors and foreign context.
- [`request_owner_test.exs`](../../test/zaq/channels/web/request_owner_test.exs):
  ordering, terminal uniqueness, timeout without cancellation and safe steps.
- [`channel_conversations_test.exs`](../../test/zaq/engine/channel_conversations_test.exs):
  identity/privacy, lazy creation, context seeding, rollback, deletion and resume.

The external widget developer owns installation and endpoint acceptance:

- Mount the actual adapter package and provide its runtime builder/children.
- Verify parent identity/session and reject forged or unverified senders before
  constructing trusted Context. Treat `sender_id` as external identity, not a ZAQ Person ID.
- Enforce configured origins, iframe policy, session expiry and subscription ownership,
  including denial for an empty allowlist.
- Reject foreign widget/config/topic selection, unauthorized chat/history access,
  unknown wire events and all inbound message-edit requests.
- Exercise first question, seeded/unseeded history, resume without reseeding,
  streaming replacement, safe failure, timeout recovery, reconnect and endpoint restart.
- Confirm these checks with the real parent app and widget package, not only the ZAQ fixture.

Host fixture conformance does **not** establish actual adapter endpoint security.
Implementation progress and outstanding acceptance decisions belong in Beadwork,
not in this contract guide.
