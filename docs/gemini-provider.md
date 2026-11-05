# Gemini voice provider

`Parlora.Providers.Gemini` connects to **gemini-3.8-live** with client backend
delegation. It uses standard Live; thinking configuration is unsupported.

```elixir
provider: {Parlora.Providers.Gemini,
  api_key: key,
  voice: "Puck"}
```

The host loads the key and passes it explicitly. Session instructions and bounded
text history come from `Parlora.start_session/1`. The supported model is fixed to
`gemini-3.8-live`. `api_version:` accepts `:v1beta` (default) or `:v1alpha`.
Do not pass `thinking_level:` or `thinking_config:`.

## Speech detection and transcription

Native settings are validated keyword lists. Unknown keys, duplicates, invalid
values and incompatible manual/automatic detection settings return an error
before connecting. With no overrides, Parlora explicitly enables automatic
detection, a 700 ms silence duration, native caller interruptions and verbatim
input transcription. Sensitivity and prefix padding remain service defaults;
language, vocabulary and interim timestamps remain opt-in. Voices remain
application choices, with `Puck` as the existing fallback.
`Parlora.Providers.Gemini.default_options/0` returns the neutral conversational
defaults. Provider tuple options override nested fields individually.

```elixir
provider: {Parlora.Providers.Gemini,
  api_key: key,
  realtime_input_config: [
    automatic_activity_detection: [
      start_of_speech_sensitivity: :low,
      end_of_speech_sensitivity: :low,
      prefix_padding_ms: 120,
      silence_duration_ms: 700
    ],
    interim_transcript_timestamp_enabled: true
  ],
  input_audio_transcription: [
    language_codes: ["en-US"],
    custom_vocabulary: ["Cedarwood", "Dr. Lee"],
    mode: :verbatim
  ]}
```

Sensitivities accept `:low` or `:high`. Durations have a local admission bound of
0–10,000 ms; that bound is not a provider quota. `activity_handling` accepts
`:start_of_activity_interrupts` or `:no_interruption`; the latter disables native
barge-in. `turn_coverage` accepts `:only_activity`, `:all_input`, or
`:audio_activity_and_all_video`.

Both input and output transcription settings accept `language_codes` (up to 16
BCP-47 hints), `custom_vocabulary` (up to 256 unique phrases of at most 256 bytes),
and `mode: :verbatim | :smart`. These are transcription controls, not output
language selection or proof that speech belongs to the caller. Keep verbatim
transcripts when interpreting corrections, conditions or consent. Gemini 3.8
selects its output language natively; application instructions can guide it.

The Gemini API endpoint currently rejects `word_timestamp` and `diarization`,
despite their presence in the shared Google SDK types. They are not exposed.
Proactive audio is permanently enabled on this model; affective dialogue and
configurable thinking are not supported.

`voiceActivity` observations are emitted as `:extension` events with
`kind: :caller_speech`, `state: :started | :finished`, and optional `offset_ms`.
Transcripts preserve available provider offsets, language, completion flags and
speaker labels. Offsets use the provider audio stream's clock, not local playback
time. Missing or malformed intervals remain unavailable. Speaker labels and VAD
observations never establish identity or consent.
Interim input transcripts are `:extension` observations with
`kind: :interim_transcript`; they do not enter caller history or authorize work.

For an application-owned speech detector, explicitly set
`realtime_input_config: [automatic_activity_detection: [disabled: true]]`, then
use `Parlora.control(session, {:user_activity, :start})` before sending the turn's
audio and `{:user_activity, :end}` when it ends. Input outside an active manual
turn is discarded. An end command drains admitted input at its normal pace before
sending the end marker; wait for its `:control_completed` event before starting
another turn. Automatic-mode sessions reject these controls. This option supplies
protocol boundaries, not a local VAD or background-speaker classifier.

To combine your application's profile with per-session overrides, use the
validated merge helper rather than a shallow `Keyword.merge/2`:

```elixir
{:ok, options} = Parlora.Providers.Gemini.merge_options(app_options,
  realtime_input_config: [
    automatic_activity_detection: [prefix_padding_ms: 200]
  ],
  input_audio_transcription: [language_codes: []])

provider = {Parlora.Providers.Gemini, Keyword.put(options, :api_key, key)}
```

The helper preserves unrelated fields at every supported nesting level. Language
and vocabulary lists replace their whole field; `[]` clears those hints. An empty
nested option group preserves inherited fields. Explicit `false` is honored;
`nil` is invalid for native Gemini fields. Invalid values and duplicate or unknown
keys in either input return `{:error, %Parlora.Error{}}`, even if an override would
otherwise hide them. Credentials are checked at provider startup.

Setting `automatic_activity_detection: [disabled: true]` removes inherited
automatic tuning. Explicitly supplying tuning alongside `disabled: true` remains
an error. Re-enable detection with `disabled: false`; discarded tuning is not
restored. Library defaults are applied separately at startup. Options are
per-session; an override never changes another session's defaults.

The booking example selects lower speech sensitivity and English clinic
vocabulary. Its clean run passed, but the café run still failed; that profile is
not promoted to library defaults. These controls do not guarantee rejection of
intelligible background speech. Native activity and interim transcripts remain
observations, never caller consent or authorization to execute backend work.

## Audio and lifecycle

Both common pipeline formats are supported: mono PCM16LE at 24 kHz for local or
browser audio, and G.711 μ-law at 8 kHz for phone audio. The adapter handles
Gemini's input/output conversion internally.

In automatic mode input runs continuously, including codec silence while idle or locally muted.
Muting does not disconnect the session. Readiness requires `setupComplete`.
Socket failure, startup expiry, receive overflow, or stale audio fails explicitly.
Close unused sessions rather than assuming an idle connection is free.

`start_session/1` automatically applies Gemini's reservoir for generated audio:
10 seconds of capacity and an 11-second residence limit, scaled to the selected
format. Channel playback buffering remains separate. Explicit `limits:` override
the defaults. Larger receive storage does not change playback speed or startup
buffering; interruptions clear retained output.

## Context and work

The provider exposes one non-blocking function, `delegate_to_backend`. Its arguments
request interpretation; your context policy and backend determine the authorized
operation and result. Corrections create or supersede task revisions through that
policy. Cancelling a provider call does not reverse an external business action.

Superseded function calls close with an empty response and `scheduling: "SILENT"`.
Their internal control status is not conversational content. The adapter retains
a superseded tombstone to reject late context and duplicate completion, while
preserving any outstanding reply watch and observed provider activity. Current
results and caller-facing clarifications still use normal response scheduling.

| Capability | Behavior |
| --- | --- |
| Speakable context | Supported |
| Quiet context and changed system instructions | Unsupported after startup |
| Context delivery | Local socket submission, outcome `:unconfirmed` |
| Input mute | Local capture gate |
| Speech/activity | Provider state reported separately from playback |
| Usage | Metadata reported by the provider; no invented final bill |
| Socket resumption | Bounded provider resumption when available; does not replay business actions |

A successful context write is not a provider acknowledgment. Assistant transcript
groups have locally generated segment IDs; timestamps are optional. Provider
speech completion also does not establish that downstream audio has finished
playing. Keep application announcements brief and coordinate them with current
speech/task state.

Google's shared SDK includes in-session system/tool replacement. On the current
Gemini API endpoint, our instruction-update probes retained the original
instruction, so the adapter continues to reject `:instruction` updates rather
than advertise unverified behavior. Session resumption and context compression
remain supported independently.

Native fields: [Live API reference](https://ai.google.dev/api/live),
[Google SDK](https://github.com/googleapis/python-genai/blob/main/google/genai/live.py),
[LiveKit turn handling](https://docs.livekit.io/agents/models/realtime/gemini/#turn-detection).

## OrderDesk selection

In the installed example, supply `GEMINI_API_KEY` and run:

```sh
PARLORA_PROVIDER=gemini scripts/browser.sh
```

The same selection applies to its local and phone launchers. Browser and phone
workflows also need the application's TypeSafe credential. See
[OrderDesk](../examples/order_desk/README.md) for setup.
