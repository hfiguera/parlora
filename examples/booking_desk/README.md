# BookingDesk

A fictional clinic receptionist built with Parlora, JEV, ReqLLM, Jido and SQLite.
The caller can ask questions or change the requested date while backend work runs.
Application rules match patient records, review insurance, validate a proposal and
require explicit approval before booking. Optional text reminders are simulated;
no real SMS is sent.

## Install and test

From this directory, install the repository's
[runtime and native prerequisites](../../docs/beam-compatibility.md), then run:

```sh
mix deps.get --check-locked
mix format --check-formatted
mix test --warnings-as-errors
```

The tests need no API keys and make no paid model calls. Local microphone mode
has been tested on macOS. Linux needs the audio libraries and running audio service
described in the prerequisites; its physical microphone path has not been verified.
Python 3.10+ is only needed for the optional scripted caller and its tests:

```sh
python3 -m unittest discover -s test -p '*_test.py'
```

For the complete Elixir quality checks, run `mix ci`. It compiles with warnings
as errors, checks compile cycles and formatting, runs the tests, and then runs
Credo, ExDNA, read-only Credence analysis and Dialyzer. These tools are development
and test dependencies; the same versions are pinned in Parlora. Credence uses
conservative assumptions and isolates compiler analysis in separate processes.
No check rewrites source or makes a model call. GitHub Actions runs this suite
and the Python tests, with a Dialyzer PLT cache keyed by runtime and dependencies.

## API keys

Live calls require `TYPESAFE_API_KEY` for JEV and `OPENAI_API_KEY` for structured
name, DOB, insurer and phone extraction. With the default OpenAI speech provider,
the same OpenAI key serves speech and extraction. Set keys in your shell:

```sh
export OPENAI_API_KEY="your-openai-key"
export TYPESAFE_API_KEY="your-typesafe-key"
```

To select another speech provider, also export its key and set `PARLORA_PROVIDER`:

| Provider | Speech model | Additional key |
| --- | --- | --- |
| `openai` (default) | `gpt-live-1` | None |
| `phonic` | `phonic-1` | `PHONIC_API_KEY` |
| `grok` | `grok-voice-3.0` | `XAI_API_KEY` |
| `gemini` | `gemini-3.8-live` | `GEMINI_API_KEY` |

The example selects Ara for Grok and Sulafat for Gemini. JEV uses `jev-1.13.0`;
structured extraction uses `openai:gpt-6-luna`. Available API credit is required for
live calls. Keep keys out of source files and recordings.

## Talk through your microphone

Use headphones and allow microphone access when prompted:

```sh
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
mix run run.exs "runs/microphone-$(date +%Y%m%d-%H%M%S)" clips --microphone
```

Wait for Ava's greeting, then ask for an appointment. No ElevenLabs key or caller
clips are needed in microphone mode; `clips` is an unused positional argument.
When asked, supply one of the seeded fictional records:

| Full name | Date of birth | Insurance on file |
| --- | --- | --- |
| Jamie Rivera | March 12, 1990 | Aetna |
| Alex Morgan | July 24, 1985 | Cigna |

The full name and DOB must match a record. This is demo record matching, not
production identity authentication. Reviewing an insurer does not verify benefits,
eligibility or network participation.

Ask for Dr. Lee on November 4, 2026, then change to November 5 while the lookup
runs. You can also start without a doctor preference and answer the assistant's
question with a doctor or "anyone available." Choose an offered time, listen to
the exact readback, then approve it. A slot choice alone never authorizes booking.
After confirmation, try the optional reminder and confirm the cell number on file.
If the number is changed or missing, a new number requires readback and approval.

Press **Enter** to save and stop. The summary reports this call's observed bookings,
simulated reminders and adapter failures. `outcome: stopped` is normal for a manual
session; `evaluation: not_evaluated` means no scripted pass/fail grade was assigned.
Ctrl+C can leave an incomplete recording.

Each command above starts a fresh in-memory database. To persist fictional changes,
set `BOOKING_DATABASE=data/my-bookings.sqlite3` instead. Recorded PCM audio and the
JSON report remain in the chosen `runs/` directory even after the process exits.

## Scripted replay

The replay caller streams generated PCM into a real speech session and waits for
backend and speech milestones. The assistant's replies are generated live. To
synthesize the caller, export `ELEVENLABS_API_KEY` and run:

```sh
python3 scripts/generate_caller.py --output clips

PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
mix run run.exs "runs/replay-$(date +%Y%m%d-%H%M%S)" clips
```

Generation uses the ElevenLabs v4 model and voice in `priv/caller.json`, verifies
compatibility, and reuses matching clips. The replay itself needs the same speech,
JEV and extraction keys as microphone mode. Its summary includes workflow checks.

To add the bundled café loop continuously to caller input before the provider:

```sh
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
mix run run.exs "runs/cafe-$(date +%Y%m%d-%H%M%S)" clips \
  --ambience priv/ambience/cafe/manifest.json
```

The background is not added to assistant output. The loop's source, CC0 license,
level and processing are documented in [the asset notes](priv/ambience/cafe/README.md).
Ambience is supported only in replay mode, not with an actual microphone.

## Application behavior

The demo clock is November 2, 2026, with appointment times in `America/Denver`.
November 4's lookup deliberately takes 25 seconds; November 5 takes 1.2 seconds.
Booking takes five seconds. These waits make concurrent conversation and date
correction observable, not representative of a production calendar's latency.
November 6 has no slots, November 11 exercises a lookup failure, and November 12
exercises a failed booking.

JEV interprets intent and readback questions. Structured extraction supplies fields
that code validates and matches against the database. Confirmed partial preferences
survive clarification; a morning/afternoon choice requires one matching verified
time. Selecting a slot creates a proposal. Readback and explicit approval precede
any booking, cancellation or rescheduling write. Repeated request IDs reuse their
stored result. A reminder failure does not undo or repeat a booking.

Calls redirect unrelated requests, warn for directed abuse, and prioritize
911/local-emergency guidance. An emergency closes the scheduling call after the
message; the demo cannot contact or transfer to emergency services. See
[call boundaries](docs/call-boundaries.md) for the policy and its limits.

The example is inspired by [Cekura's appointment workflow](https://github.com/cekura-ai/cekura-bench/tree/4bb3aca8b4e96cbb71f2434ad6163a2ecb1df278/agent-definitions/appointments).
It is not an implementation of or a score on that benchmark.
