# Getting started

For a complete runnable application, follow [Your first working session](first-session.md).
This guide covers integration choices and the session API. A session combines:

- A **channel** for caller audio: browser, local devices, Twilio, or Telnyx.
- A **provider** for full-duplex speech: OpenAI, Gemini, Grok, or Phonic.
- A **backend** for application work: Jido, Sagents, Legion, or your own adapter.
- A **context policy** that turns conversation and application state into work.

The policy owns interpretation and task selection. The backend owns execution.
Your application owns authorization, confirmations, and persistence. Audio always
travels through Parlora, including browser calls.

## Speech-to-speech and full-duplex

These terms describe different aspects of a voice application:

- **Speech-to-speech** describes a provider that accepts audio and generates
  spoken responses. Your application does not need to connect separate speech
  recognition and speech synthesis services for that conversation.
- **Full-duplex** means audio input and output can flow concurrently. Caller
  audio can continue while assistant audio is generated or played. The selected
  provider's turn-taking and interruption behavior still apply.
- **Cascaded** describes a pipeline with separate speech-to-text (STT), language
  model (LLM), and text-to-speech (TTS) stages. A cascaded system can also support
  full-duplex interaction; the terms are not opposites.

Parlora's built-in providers expose speech-to-speech sessions. Parlora does not
provide independent STT, LLM, and TTS stages for assembling a cascaded pipeline.
This focus lets Parlora coordinate continuous audio and application work through
one voice session contract, while backend tasks run independently. A separate
text model in a backend performs application work; it does not replace the voice
provider or add a TTS stage.

## 1. Install

Install the [runtime and native prerequisites](beam-compatibility.md) first.
Add Parlora to your application's dependencies:

```elixir
defp deps do
  [
    {:parlora, "~> 0.2.0"},
    {:jido, "~> 2.4.0"}
  ]
end
```

This guide uses Jido; omit it if you implement
`Parlora.Backend`, or select [Sagents](sagents-backend.md) or [Legion](legion-backend.md).
The frameworks are optional and do not select the voice provider.

Run `mix deps.get` and commit your application's lockfile. Dependency configuration
files are not inherited: put native settings and runtime secrets in the host
application's own config.

## 2. Choose a starting example

The opening-hours tutorial uses local audio, one API key from the voice provider,
and a deterministic Jido action.

[OrderDesk](../examples/order_desk/README.md) includes the application policy,
backend, browser client, and storage. Use it for browser conversations, order
corrections, or phone workflows. Its browser launcher needs an API key for the voice provider
and a `TYPESAFE_API_KEY` for application interpretation. The terminal example
uses a smaller policy and needs only an API key for the voice provider.

## 3. Configure credentials and supervision

Read credentials at runtime using your application's secret management. For
configuration through environment variables, put this in `config/runtime.exs`:

```elixir
import Config
config :my_app, :openai_api_key, System.fetch_env!("OPENAI_API_KEY")
```

Pass the key explicitly to the provider. Parlora does not read environment
variables or Keychain. Keep credentials out of source and configuration read at
compile time.

Mix starts Parlora's application automatically. When using Jido, add an instance
to your application's supervision tree:

```elixir
children = [
  {Jido, name: MyApp.Jido}
]
```

Define your agent, result mapper, and policy in your application. The
[Jido guide](jido-backend.md) shows how to connect them to your own operations.
A deterministic Jido action needs no language model.

## 4. Own the session lifecycle

Use the complete startup and event loop in the [tutorial for your first session](first-session.md)
as a starting point. `Parlora.start_session/1` takes four required `{module, options}`
tuples: `channel:`, `provider:`, `backend:`, and `context_policy:`. Optional settings
include instructions, application context, history, an event sink, and limits.
See `Parlora.start_session/1` for the API details.

The event sink must be a process that stays alive, usually an application GenServer
or the channel's signaling owner. Starting a session returns before it is ready.
In an existing GenServer receiver, include handlers for session readiness and
closure, and route other events to your application as appropriate:

```elixir
def handle_info({:parlora_event, %Parlora.Event{source: :session, type: :ready}}, state) do
  {:noreply, Map.put(state, :voice_ready?, true)}
end

def handle_info({:parlora_event, %Parlora.Event{source: :session, type: :closed}}, state) do
  {:noreply, Map.put(state, :session, nil)}
end

def handle_info({:parlora_event, %Parlora.Event{}}, state) do
  # Route failures, captions, and work progress to your application UI.
  {:noreply, state}
end
```

The first two clauses handle events emitted by the session itself; adapters also
emit their own `:ready` and `:closed` events. Use the session `:ready` event to invite speech.
A greeting is application policy; do not assume startup automatically speaks.

For browser audio, let the [signaling route](browser-channel.md) supply the channel
tuple and keep `event_sink: self()` in its session factory. Phone sessions use
[Twilio](twilio-channel.md) or [Telnyx](telnyx-channel.md) with
`audio_format: Parlora.AudioFormat.pcmu()`.

## 5. Observe, control, and close

| Operation | API |
| --- | --- |
| Receive events in another process | `Parlora.subscribe(session, pid)` |
| Inspect operational state | `Parlora.status(session)` |
| Read current context and transcripts | `Parlora.snapshot(session)` |
| Replace application context | `Parlora.update_context(session, context)` |
| Add provider context | `Parlora.append_context(session, update)` |
| Mute capture | `Parlora.control(session, {:input_muted, true})` |
| Suppress new output | `Parlora.control(session, {:suppress_output, true})` |
| Resume output | `Parlora.control(session, {:suppress_output, false})` |
| Clear buffered output | `Parlora.control(session, {:clear_output, :next})` |
| Request job cancellation | `Parlora.cancel(session, request_id, reason)` |
| Close and stop work | `Parlora.close(session, :cancel)` |
| Close after allowing work to finish within the shutdown deadline | `Parlora.close(session, :finish)` |

Controls depend on the selected adapters' capabilities. Inspect
`Parlora.Status` and the [API contract](public-interfaces.md) for exact outcomes.
`status/1` omits transcript history and full task/result contents, but optional
clarification data may contain application content. Treat snapshots and events
as application data, not automatically redacted telemetry.

`close/2` admits a bounded shutdown. Observe session `:closed` for its outcome;
monitor the session process if you need to wait for its exit. A cancellation
request does not prove an external operation was reversed. Preserve operation
idempotency and reconcile uncertain writes in your application.

For runtime metrics, distributed traces and logging integration, see
[Metrics, traces and logs](observability.md).

## Provider selection and reliability

Use [OpenAI](openai-provider.md), [Gemini](gemini-provider.md),
[Grok](grok-provider.md), or [Phonic](phonic-provider.md) in the provider tuple. `start_session/1` applies each
provider's audio storage defaults automatically; explicit `limits:` override them.
Channel playback buffering is separate from provider receive storage.

Use `Parlora.expect_progress/4` when your application expects an event within a
finite interval. Ordinary caller silence has no deadline. A provider accepting
context, generating speech, and the caller hearing it are separate observations.
See [session health](public-interfaces.md#15-session-health-and-opt-in-progress-deadlines)
and [OpenAI output recovery](output-recovery.md).

Sessions are in memory. Persist business data in your application and supply
bounded `history:` and `context:` when starting a fresh session. Reconnection is
not permission to replay business actions.
