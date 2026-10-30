# Parlora

**Build voice AI agents that talk with people and work with your application.**

Parlora is an Elixir framework for building real-time voice AI agents. It connects
speech-to-speech models to your application's services and agent backends, with
audio through browsers, phone calls, or local microphones and speakers.

For example, a caller can ask about an order, keep talking while the lookup runs,
then correct the order number. Your application's policy interprets the request
and correction. Parlora coordinates the backend tasks and filters outdated task
results before sending them to the voice provider for a spoken response.

All audio passes through Parlora. Your application controls business rules,
authorization, confirmations, and storage.

## Why use Parlora?

- **Connect conversation to useful work.** Run application actions while the
  voice conversation continues, such as looking up an order or preparing a change
  for confirmation.
- **Handle changing requests.** Coordinate follow-ups, task corrections,
  cancellation requests, and result delivery through your application policy.
- **Choose integrations independently.** Combine a supported audio channel,
  voice provider, and backend without tying all three to one vendor or framework.
- **Reuse the session runtime.** Parlora provides audio queues, playback controls,
  lifecycle deadlines, cleanup, and events for observing each session.

## Built for speech-to-speech conversation

Parlora focuses on full-duplex speech-to-speech providers: models that accept
audio and generate spoken responses while caller audio can continue flowing.

Parlora currently integrates these providers directly rather than assembling
separate speech recognition, text generation, and speech synthesis services.
The [integration guide](docs/using-parlora.md#speech-to-speech-and-full-duplex)
explains these terms in more detail.

## Supported integrations

| Audio channels | Voice providers | Backend integrations |
| --- | --- | --- |
| Browser WebRTC, local microphone/speakers, Twilio, Telnyx | OpenAI GPT-Live-1, Gemini 3.8 Live, Grok Voice 3.0, Phonic-1 | Jido, Sagents, Legion, or your own `Parlora.Backend` |

Phonic-1 is a supported speech-to-speech provider in Parlora.
See the [Phonic guide](docs/phonic-provider.md#integration-status) for validation
evidence and remaining qualification limits.

Jido, Sagents, and Legion are optional. Install only the framework you use.
The voice provider handles the spoken conversation and delegates application
work to the backend, which can run deterministic actions or use a separate text
model.

## Getting started

Start with [your first working session](docs/first-session.md). It walks you
through creating a small Mix application, copying the complete example code,
supplying one API key from your voice provider, and running a local voice session.
You can ask for a demo shop's opening hours and hear the result of a read-only
Jido action.

Install Parlora from [Hex](https://hex.pm/packages/parlora):

```elixir
{:parlora, "~> 0.2.0"}
```

You need **Elixir 1.18+ (1.x)**, **Erlang/OTP 27+**, and the
[native prerequisites](docs/beam-compatibility.md). The tutorial uses your local
microphone and speakers, builds only the native bindings needed for local audio,
and includes the context policy, event loop, and session cleanup.

## Build your own application

Once the first session works, adapt its four components to your application:
audio channel, voice provider, backend action, and context policy.
The [integration guide](docs/using-parlora.md) covers applications that stay running;
the [Jido guide](docs/jido-backend.md) explains agent and result mapping details.

## Explore the OrderDesk example

[OrderDesk](examples/order_desk/README.md) is a complete application for exploring
order lookups, corrections, and draft delivery instructions that require separate
confirmation in the browser. It uses fictional records in SQLite and Jido as the
default backend.

Its setup guide covers installation, credentials for the example, provider and
backend selection, and launch commands for browser, local audio, and incoming
phone calls. Use it to explore these workflows after your first working session.

## Guides

- **Start here:** [First working session](docs/first-session.md), [Use Parlora](docs/using-parlora.md), [requirements and native builds](docs/beam-compatibility.md).
- **Channels:** [Browser](docs/browser-channel.md), [Twilio](docs/twilio-channel.md), [Telnyx](docs/telnyx-channel.md). Local audio options are documented in `Parlora.Channels.LocalAudio`.
- **Providers:** [OpenAI](docs/openai-provider.md), [Gemini](docs/gemini-provider.md), [Grok](docs/grok-provider.md), [Phonic](docs/phonic-provider.md).
- **Backends:** [Jido](docs/jido-backend.md), [Sagents](docs/sagents-backend.md), [Legion](docs/legion-backend.md).
- **Reference:** [Adapter contracts and data](docs/public-interfaces.md), [metrics, traces and logs](docs/observability.md).

Sessions live in memory. Your application persists business state and supplies
history/context when starting a fresh session. Cancellation and corrections do
not undo external side effects. A provider accepting a result is separate from
that result being spoken or heard.

## Behind the name

Parlora is a coined name inspired by the Italian *parlare* ("to speak") and *ora*
("now"). It evokes "conversation in the moment"—the idea of keeping a conversation
flowing while your application gets things done. It is wordplay, rather than a
literal Italian translation.

## License

Parlora is released under the [MIT License](LICENSE).
