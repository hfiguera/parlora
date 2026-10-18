The Gemini Live API supports low-latency, real-time speech-to-text transcription using the [`gemini-3.5-transcribe-live`](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe) model. By connecting to the Live API over WebSockets or using the Google Gen AI SDK, you can stream continuous audio input and receive incremental, real-time text transcriptions as speech occurs.
[Try Live Transcription in Google AI Studio](https://aistudio.google.com/live?model=gemini-3.5-transcribe-live) [Open the Colab cookbook](https://github.com/google-gemini/cookbook) [Use coding agent skills](https://ai.google.dev/gemini-api/docs/coding-agents#gemini-live-api-dev)

By leveraging the Gemini Live API, developer platforms such as
[Agora](https://docs.agora.io/en/ai/models/asr/gemini),
[Fishjam](https://docs.fishjam.io/tutorials/gemini-live-integration),
[LiveKit](https://docs.livekit.io/agents/models/stt/gemini/),
[Pipecat](https://docs.pipecat.ai/api-reference/server/services/stt/google),
[Vercel](https://vercel.com/docs/ai-gateway/modalities/speech-to-text), and
[Vision Agents](https://visionagents.ai/integrations/stt/gemini)
enable developers to build and deploy high-performance voice-driven interfaces
with ease. These platforms manage complex real-time media streaming
infrastructure behind the scenes, allowing developers to focus entirely on
crafting the user experience.

## Live agent versus live Transcription

While both use the Live API bidirectional streaming connection, Live Transcription operates as a dedicated, low-latency speech recognition pipeline rather than a conversational agent.

| Feature | Live Agent | Live Transcription |
|---|---|---|
| **Primary role** | Conversational assistant that listens, reasons, and speaks back. | Real-time speech-to-text pipeline that transcribes incoming audio. |
| **Response modality** | Spoken audio and text (`response_modalities=["AUDIO"]`). | Streaming text transcriptions (`response_modalities=["TEXT"]`). |
| **Interaction style** | Turn-based dialogue with pause detection and interruptions. | Continuous stream processing as the speaker talks. |
| **Supported features** | Function calling, Google Search, system instructions. | Speech biasing (`custom_vocabulary`), language detection, manual \& hybrid VAD, Smart transcription. |
| **Input stream** | Multimodal: audio, video, images, text. | Audio input (raw 16-bit PCM). |

## Get started

The following examples demonstrate how to open a bidirectional streaming session with `gemini-3.5-transcribe-live` and receive real-time transcriptions.

### Python

    import asyncio
    from google import genai
    from google.genai import types

    client = genai.Client()
    model = "gemini-3.5-transcribe-live"

    config = types.LiveConnectConfig(
        response_modalities=["TEXT"],
        input_audio_transcription=types.AudioTranscriptionConfig(
            language_codes=[],  # Automatic language detection
        ),
    )

    async def main():
        async with client.aio.live.connect(model=model, config=config) as session:
            print("Session established with Live Transcription")

            # Receive transcription events
            async for response in session.receive():
                server_content = response.server_content
                if server_content and server_content.input_transcription:
                    print("Transcript:", server_content.input_transcription.text)

    if __name__ == "__main__":
        asyncio.run(main())

### JavaScript

    import { GoogleGenAI, Modality } from '@google/genai';

    const ai = new GoogleGenAI({});
    const model = 'gemini-3.5-transcribe-live';

    const config = {
      responseModalities: [Modality.TEXT],
      inputAudioTranscription: {
        languageCodes: [], // Automatic language detection
      },
    };

    async function main() {
      const session = await ai.live.connect({
        model: model,
        config: config,
        callbacks: {
          onopen: () => console.log('Connected to Live Transcription'),
          onmessage: (message) => {
            const content = message.serverContent;
            if (content?.inputTranscription) {
              console.log('Transcript:', content.inputTranscription.text);
            }
          },
          onerror: (e) => console.error('Error:', e.message),
          onclose: (e) => console.log('Connection closed:', e.reason),
        },
      });
    }

    main();

### WebSockets

    const API_KEY = "YOUR_API_KEY";
    const MODEL_NAME = "gemini-3.5-transcribe-live";
    const WS_URL = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${API_KEY}`;

    const websocket = new WebSocket(WS_URL);

    websocket.onopen = () => {
      console.log('WebSocket connected');

      const setupMessage = {
        setup: {
          model: `models/${MODEL_NAME}`,
          generationConfig: {
            responseModalities: ['TEXT'],
          },
          inputAudioTranscription: {
            languageCodes: []
          }
        }
      };
      websocket.send(JSON.stringify(setupMessage));
    };

    websocket.onmessage = (event) => {
      const response = JSON.parse(event.data);
      const content = response.serverContent;
      if (content?.inputTranscription) {
        console.log('Transcript:', content.inputTranscription.text);
      }
    };

## Interim and finalized transcriptions

As audio streams into the Live API, the server emits two complementary transcription fields within `server_content`:

- **`interim_input_transcription`** : low-latency, speculative partial hypotheses updated while the speaker is actively talking. These partial updates occur rapidly with minimal delay. Use `interim_input_transcription` to render responsive live UI subtitles or preview captions.
- **`input_transcription`**: the finalized transcript emitted when the speaker pauses, the turn completes, or speech is finalized. Once emitted, this text represents the model's authoritative transcription of that speech segment. In smart transcription mode, this will include the cleaned, formatted response.

The following example demonstrates how to display streaming interim partials and commit final transcripts:

### Python

    async def receive_transcripts(session):
        async for response in session.receive():
            server_content = response.server_content
            if not server_content:
                continue

            # Real-time interim hypothesis (updates dynamically as user speaks)
            if server_content.interim_input_transcription:
                interim_text = server_content.interim_input_transcription.text
                print(f"\r[Interim] {interim_text}", end="", flush=True)

            # Finalized transcript (emitted on speech completion)
            if server_content.input_transcription:
                final_text = server_content.input_transcription.text
                print(f"\n[Final] {final_text}")

### JavaScript

    onmessage: (message) => {
      const content = message.serverContent;
      if (!content) return;

      if (content.interimInputTranscription) {
        // Update live subtitle preview on screen
        renderInterimPreview(content.interimInputTranscription.text);
      }

      if (content.inputTranscription) {
        // Append final committed transcript to chat history
        commitFinalTranscript(content.inputTranscription.text);
      }
    };

### WebSockets

    websocket.onmessage = (event) => {
      const response = JSON.parse(event.data);
      const content = response.serverContent;
      if (content?.interimInputTranscription) {
        console.log('[Interim]:', content.interimInputTranscription.text);
      }
      if (content?.inputTranscription) {
        console.log('[Final]:', content.inputTranscription.text);
      }
    };

## Sending audio

Stream audio chunks over the active connection as raw 16-bit PCM audio.

- **Audio format:** Raw 16-bit PCM at 16kHz (mono, little-endian).
- **Chunk size:** Send audio in chunks of 100ms (1,024 to 2,048 frames).
- **MIME type:** `audio/pcm;rate=16000` (or the matching sample rate).

### Python

    # Stream a raw PCM audio chunk
    await session.send_realtime_input(
        audio=types.Blob(
            data=audio_chunk_bytes,
            mime_type="audio/pcm;rate=16000"
        )
    )

    # Signal the end of the audio stream when finished
    await session.send_realtime_input(audio_stream_end=True)

### JavaScript

    // Send base64-encoded PCM audio chunk
    session.sendRealtimeInput({
      audio: {
        data: audioChunkBase64,
        mimeType: 'audio/pcm;rate=16000'
      }
    });

    // Signal stream end
    session.sendRealtimeInput({
      audioStreamEnd: true
    });

### WebSockets

    // Send base64-encoded PCM audio chunk
    websocket.send(JSON.stringify({
      realtimeInput: {
        audio: {
          data: audioChunkBase64,
          mimeType: 'audio/pcm;rate=16000'
        }
      }
    }));

    // Signal stream end
    websocket.send(JSON.stringify({
      realtimeInput: {
        audioStreamEnd: true
      }
    }));

## Transcription features

### Automatic language detection

By default, omitting `language_codes` or setting `language_codes=[]` enables automatic language identification. The model dynamically detects the spoken language across utterances, including multilingual conversations and code-switching.

### Python

    config = types.LiveConnectConfig(
        response_modalities=["TEXT"],
        input_audio_transcription=types.AudioTranscriptionConfig(
            language_codes=[],
        ),
    )

### JavaScript

    const config = {
      responseModalities: [Modality.TEXT],
      inputAudioTranscription: {
        languageCodes: [],
      },
    };

### WebSockets

    const setupMessage = {
      setup: {
        model: 'models/gemini-3.5-transcribe-live',
        generationConfig: {
          responseModalities: ['TEXT'],
        },
        inputAudioTranscription: {
          languageCodes: [],
        },
      },
    };
    websocket.send(JSON.stringify(setupMessage));

### Specific language hint

Provide explicit BCP-47 language codes (for example, `["es-ES"]` for Spanish or `["fr-FR"]` for French) to bias recognition toward specific languages (see [Supported languages](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe#supported-languages)).

### Python

    config = types.LiveConnectConfig(
        response_modalities=["TEXT"],
        input_audio_transcription=types.AudioTranscriptionConfig(
            language_codes=["es-ES"],
        ),
    )

### JavaScript

    const config = {
      responseModalities: [Modality.TEXT],
      inputAudioTranscription: {
        languageCodes: ['es-ES'],
      },
    };

### WebSockets

    const setupMessage = {
      setup: {
        model: 'models/gemini-3.5-transcribe-live',
        generationConfig: {
          responseModalities: ['TEXT'],
        },
        inputAudioTranscription: {
          languageCodes: ['es-ES'],
        },
      },
    };
    websocket.send(JSON.stringify(setupMessage));

### Custom vocabulary biasing

Provide a list of up to 1,000 phrases, proper nouns, brand names, or technical terms in `custom_vocabulary` to bias speech recognition toward specific terminology (best results are typically achieved with up to 100 terms).

### Python

    config = types.LiveConnectConfig(
        response_modalities=["TEXT"],
        input_audio_transcription=types.AudioTranscriptionConfig(
            language_codes=[],
            custom_vocabulary=["Gemini", "Kubernetes", "BigQuery"],
        ),
    )

### JavaScript

    const config = {
      responseModalities: [Modality.TEXT],
      inputAudioTranscription: {
        languageCodes: [],
        customVocabulary: ['Gemini', 'Kubernetes', 'BigQuery'],
      },
    };

### WebSockets

    const setupMessage = {
      setup: {
        model: 'models/gemini-3.5-transcribe-live',
        generationConfig: {
          responseModalities: ['TEXT'],
        },
        inputAudioTranscription: {
          languageCodes: [],
          customVocabulary: ['Gemini', 'Kubernetes', 'BigQuery'],
        },
      },
    };
    websocket.send(JSON.stringify(setupMessage));

### Smart transcription

Configure transcription output formatting using the `mode` parameter in `input_audio_transcription`:

- **`VERBATIM` (default)**: Produces an exact literal transcript of everything spoken, preserving raw filler words ("um", "uh", "like"), repetitions, and false starts.
- **`SMART` (Smart transcription)**: Cleans up and structures the transcript for readability:

  - **Disfluency removal**: Removes filler words, stuttering, and false starts.
  - **Inline self-corrections**: Resolves spoken corrections naturally.
  - **Structured formatting**: Automatically formats lists, bullet points, numbers, dates, and paragraph breaks.
  - **Grammar \& casing**: Applies natural capitalization and punctuation polish.

### Python

    config = types.LiveConnectConfig(
        response_modalities=["TEXT"],
        input_audio_transcription=types.AudioTranscriptionConfig(
            mode="SMART",
        ),
    )

### JavaScript

    const config = {
      responseModalities: [Modality.TEXT],
      inputAudioTranscription: {
        mode: 'SMART',
      },
    };

### WebSockets

    const setupMessage = {
      setup: {
        model: 'models/gemini-3.5-transcribe-live',
        generationConfig: {
          responseModalities: ['TEXT'],
        },
        inputAudioTranscription: {
          mode: 'SMART',
        },
      },
    };
    websocket.send(JSON.stringify(setupMessage));

## Voice Activity Detection (VAD) strategies

### Automatic VAD (Default)

By default, server-side automatic Voice Activity Detection detects when a speaker begins and stops speaking.

### Hybrid VAD

[Hybrid VAD](https://ai.google.dev/gemini-api/docs/live-api/capabilities#hybrid-vad) combines server-side automatic speech start detection with client-side speech end detection for zero-latency turn finalization:

1. **Server-side automatic VAD remains enabled** to detect speech beginnings accurately with prefix audio padding, preventing front-word truncation.
2. **Client-side VAD detects silence** : When a local on-device VAD detects that the speaker has stopped talking, the client sends an `audio_stream_end` signal immediately.
3. **Fast finalization** : The server treats `audio_stream_end` as an immediate turn finalization prompt, bypassing the default server-side silence wait time and returning the finalized transcript with minimal latency.
4. **Fallback**: If the client VAD fails to trigger, the server-side VAD acts as an automatic fallback.

### Python

    config = types.LiveConnectConfig(
        response_modalities=["TEXT"],
        input_audio_transcription=types.AudioTranscriptionConfig(),
    )

    async with client.aio.live.connect(model=model, config=config) as session:
        # Stream audio chunks...
        await session.send_realtime_input(
            audio=types.Blob(data=chunk, mime_type="audio/pcm;rate=16000")
        )

        # When client-side VAD detects end of speech, send audio_stream_end:
        await session.send_realtime_input(audio_stream_end=True)

### JavaScript

    const config = {
      responseModalities: [Modality.TEXT],
      inputAudioTranscription: {},
    };

    // Stream audio...
    session.sendRealtimeInput({
      audio: { data: chunkBase64, mimeType: 'audio/pcm;rate=16000' }
    });

    // When client VAD detects end of speech, send audioStreamEnd:
    session.sendRealtimeInput({
      audioStreamEnd: true
    });

### WebSockets

    const setupMessage = {
      setup: {
        model: 'models/gemini-3.5-transcribe-live',
        generationConfig: {
          responseModalities: ['TEXT'],
        },
        inputAudioTranscription: {},
      },
    };
    websocket.send(JSON.stringify(setupMessage));

    // Stream audio...
    websocket.send(JSON.stringify({
      realtimeInput: {
        audio: { data: chunkBase64, mimeType: 'audio/pcm;rate=16000' }
      }
    }));

    // When client VAD detects end of speech, send audioStreamEnd:
    websocket.send(JSON.stringify({
      realtimeInput: {
        audioStreamEnd: true
      }
    }));

### Manual VAD (Push-to-Talk)

For walkie-talkie interfaces or push-to-talk buttons, disable automatic VAD entirely and control turn boundaries explicitly using `activity_start` and `activity_end`:

### Python

    config = types.LiveConnectConfig(
        response_modalities=["TEXT"],
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(
                disabled=True
            )
        ),
        input_audio_transcription=types.AudioTranscriptionConfig(),
    )

    async with client.aio.live.connect(model=model, config=config) as session:
        # Button pressed: signal speech start
        await session.send_realtime_input(activity_start=types.ActivityStart())

        # Stream audio chunks...
        await session.send_realtime_input(audio=types.Blob(data=chunk, mime_type="audio/pcm;rate=16000"))

        # Button released: signal speech end
        await session.send_realtime_input(activity_end=types.ActivityEnd())

### JavaScript

    const config = {
      responseModalities: [Modality.TEXT],
      realtimeInputConfig: {
        automaticActivityDetection: {
          disabled: true,
        },
      },
      inputAudioTranscription: {},
    };

    // Signal speech start
    session.sendRealtimeInput({ activityStart: {} });

    // Stream audio...

    // Signal speech end
    session.sendRealtimeInput({ activityEnd: {} });

### WebSockets

    const setupMessage = {
      setup: {
        model: 'models/gemini-3.5-transcribe-live',
        generationConfig: {
          responseModalities: ['TEXT'],
        },
        realtimeInputConfig: {
          automaticActivityDetection: {
            disabled: true,
          },
        },
        inputAudioTranscription: {},
      },
    };
    websocket.send(JSON.stringify(setupMessage));

    // Button pressed: signal speech start
    websocket.send(JSON.stringify({
      realtimeInput: {
        activityStart: {},
      },
    }));

    // Stream audio...
    websocket.send(JSON.stringify({
      realtimeInput: {
        audio: { data: chunkBase64, mimeType: 'audio/pcm;rate=16000' },
      },
    }));

    // Button released: signal speech end
    websocket.send(JSON.stringify({
      realtimeInput: {
        activityEnd: {},
      },
    }));

## Ephemeral tokens in client applications

For client-to-server applications (such as mobile or web apps streaming directly from a microphone), use [ephemeral tokens](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens) to avoid exposing your API key in client code.

Create a constrained ephemeral token on your server before initiating the client connection:

### Python

    import datetime
    from google import genai

    client = genai.Client()
    expire_time = datetime.datetime.now(tz=datetime.timezone.utc) + datetime.timedelta(minutes=30)

    token = client.auth_tokens.create(
        config={
            "uses": 1,
            "expire_time": expire_time,
            "live_connect_constraints": {
                "model": "gemini-3.5-transcribe-live",
                "config": {
                    "response_modalities": ["TEXT"],
                    "input_audio_transcription": {
                        "language_codes": [],
                    },
                },
            },
        }
    )

### JavaScript

    import { GoogleGenAI } from '@google/genai';

    const client = new GoogleGenAI({});
    const expireTime = new Date(Date.now() + 30 * 60 * 1000).toISOString();

    const token = await client.authTokens.create({
      config: {
        uses: 1,
        expireTime: expireTime,
        liveConnectConstraints: {
          model: 'gemini-3.5-transcribe-live',
          config: {
            responseModalities: ['TEXT'],
            inputAudioTranscription: {
              languageCodes: [],
            },
          },
        },
      },
    });

### REST

    curl -X POST "https://generativelanguage.googleapis.com/v1beta/auth_tokens" \
      -H "x-goog-api-key: ${GEMINI_API_KEY}" \
      -H "Content-Type: application/json" \
      -d '{
        "uses": 1,
        "expireTime": "YYYY-MM-DDTHH:MM:SSZ",
        "liveConnectConstraints": {
          "model": "models/gemini-3.5-transcribe-live",
          "config": {
            "responseModalities": ["TEXT"],
            "inputAudioTranscription": {
              "languageCodes": []
            }
          }
        }
      }'

## Supported languages

The following languages and BCP-47 language codes are supported for Gemini 3.5 Transcribe Live:

| Language | BCP-47 Code | Language | BCP-47 Code |
|---|---|---|---|
| Afrikaans | `af-ZA` | Japanese | `ja-JP` |
| Amharic | `am-ET` | Javanese | `jv-ID` |
| Arabic (Egypt) | `ar-EG` | Kabuverdianu | `kea-CV` |
| Armenian | `hy-AM` | Kannada | `kn-IN` |
| Assamese | `as-IN` | Kazakh | `kk-KZ` |
| Azerbaijani | `az-AZ` | Korean | `ko-KR` |
| Belarusian | `be-BY` | Kyrgyz | `ky-KG` |
| Bengali (Bangladesh) | `bn-BD` | Latvian | `lv-LV` |
| Bengali (India) | `bn-IN` | Lingala | `ln-CD` |
| Bosnian | `bs-BA` | Lithuanian | `lt-LT` |
| Bulgarian | `bg-BG` | Macedonian | `mk-MK` |
| Bulgarian (Aromanian) | `rup-BG` | Malay | `ms-MY` |
| Burmese | `my-MM` | Malayalam | `ml-IN` |
| Cantonese (Traditional) | `yue-Hant-HK` | Maltese | `mt-MT` |
| Catalan | `ca-ES` | Mandarin Chinese (Simplified) | `cmn-Hans-CN` |
| Cebuano | `ceb` | Marathi | `mr-IN` |
| Central Khmer | `km-KH` | Mongolian | `mn-MN` |
| Croatian | `hr-HR` | Nepali | `ne-NP` |
| Czech | `cs-CZ` | Norwegian | `nb-NO` |
| Danish | `da-DK` | Oriya | `or-IN` |
| Dutch | `nl-NL` | Polish | `pl-PL` |
| English (Great Britain) | `en-GB` | Portuguese (Brazil) | `pt-BR` |
| English (India) | `en-IN` | Portuguese (Portugal) | `pt-PT` |
| English (United States) | `en-US` | Punjabi | `pa-IN` |
| Estonian | `et-EE` | Punjabi (Gurmukhi script) | `pa-Guru-IN` |
| Farsi | `fa-IR` | Romanian | `ro-RO` |
| Filipino | `fil-PH` | Russian | `ru-RU` |
| Finnish | `fi-FI` | Serbian | `sr-RS` |
| French | `fr-FR` | Sindhi (Arabic script) | `sd-Arab-IN` |
| Galician | `gl-ES` | Slovak | `sk-SK` |
| Georgian | `ka-GE` | Slovenian | `sl-SI` |
| German | `de-DE` | Spanish (Latin America) | `es-419` |
| Greek | `el-GR` | Spanish (United States) | `es-US` |
| Gujarati | `gu-IN` | Swahili (Kenya) | `sw-KE` |
| Hausa | `ha-NG` | Swedish | `sv-SE` |
| Hebrew | `he-IL` | Tajik | `tg-TJ` |
| Hindi | `hi-IN` | Telugu | `te-IN` |
| Hungarian | `hu-HU` | Thai | `th-TH` |
| Icelandic | `is-IS` | Turkish | `tr-TR` |
| Indian English | `en-IN` | Ukrainian | `uk-UA` |
| Indonesian | `id-ID` | Uzbek | `uz-UZ` |
| Italian | `it-IT` | Vietnamese | `vi-VN` |

## Parameter reference

Configure live transcription using fields in `input_audio_transcription` and `realtime_input_config`:

| Parameter | Type | Description |
|---|---|---|
| `language_codes` | Array of strings | BCP-47 language codes (e.g., `["en-US"]`). If omitted or empty (`[]`), the model automatically detects the language and handles multilingual speech. |
| `custom_vocabulary` | Array of strings | Up to 1,000 custom terms, acronyms, brand names, or proper nouns to bias speech recognition. |
| `mode` | String | Transcription mode: `"VERBATIM"` (default) or `"SMART"` (Smart transcription). When set to `"SMART"`, the model removes filler words, formats lists, and corrects disfluencies. |
| `automatic_activity_detection.disabled` | Boolean | Set to `true` to disable automatic voice activity detection and manually send `activityStart` and `activityEnd` signals. |

### Server response fields

| Field | Description |
|---|---|
| `server_content.interim_input_transcription` | Low-latency, interim partial transcription hypothesis emitted continuously while the user is actively speaking. |
| `server_content.input_transcription` | Finalized, authoritative input transcript emitted when a speech turn finishes. |

## Limitations

- **Session duration:** Live transcription sessions support continuous streaming for up to 10 minutes.
- **Speaker diarization:** Speaker diarization is not supported in live streaming sessions. For speaker diarization, use the non-streaming [Audio transcription](https://ai.google.dev/gemini-api/docs/transcribe#speaker-diarization) endpoint.
- **Word-level timestamps:** Word-level timestamps are not supported over the Live API. The Live API emits utterance-level timestamps (`interim_input_transcription` and `input_transcription`).
- **Custom vocabulary:** You can provide up to 1,000 terms in `custom_vocabulary`, but best results are typically achieved with up to 100 terms.
- **Mode compatibility:** Smart transcription (`"mode": "SMART"`) removes filler words and formats intent-aware text, but cannot be combined with word annotations.

## What's next

- Read the [Gemini Transcribe documentation](https://ai.google.dev/gemini-api/docs/transcribe) for non-streaming audio files.
- Read the [Live API overview](https://ai.google.dev/gemini-api/docs/live-api) for conversational voice agents.
- Read the [Live translation guide](https://ai.google.dev/gemini-api/docs/live-api/live-translate) for real-time speech-to-speech translation.
- Check the [Pricing page](https://ai.google.dev/gemini-api/docs/pricing#gemini-3.5-transcribe-live) for Live API streaming pricing.
- Explore the [Live API capabilities guide](https://ai.google.dev/gemini-api/docs/live-api/capabilities).