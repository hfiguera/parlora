> [!WARNING]
> **Preview:** The Live API is in preview.

This is a comprehensive guide that covers capabilities and configurations
available with the Live API.
See [Get started with Live API](https://ai.google.dev/gemini-api/docs/live) page for an
overview and sample code for common use cases.

## Before you begin

- **Familiarize yourself with core concepts:** If you haven't already done so, read the [Get started with Live API](https://ai.google.dev/gemini-api/docs/live) page first. This will introduce you to the fundamental principles of the Live API, how it works, and the different [implementation approaches](https://ai.google.dev/gemini-api/docs/live#implementation-approach).
- **Try the Live API in AI Studio:** You may find it useful to try the Live API in [Google AI Studio](https://aistudio.google.com/app/live) before you start building. To use the Live API in Google AI Studio, select **Stream**.

## Model comparison

The following table summarizes the key differences between the
[Gemini 3.8 Live](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live),
[Gemini 3.8 Live Extended Thinking](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live-extended-thinking), and
[Gemini 3.1 Flash Live Preview](https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-live-preview) models:

| Feature | Gemini 3.8 Live | Gemini 3.8 Live Extended Thinking | Gemini 3.1 Flash Live Preview |
|---|---|---|---|
| **Recommended for** | Default option for most low-latency voice agent experiences. | Recommended when higher background reasoning is required. | Legacy preview model. We recommend updating to [Gemini 3.8 Live](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live). |
| **[Thinking](https://ai.google.dev/gemini-api/docs/live-api/capabilities#native-audio-output-thinking)** | Supported (interleaved reasoning). `thinkingLevel` is not supported (omit from setup). | Supported. Configurable background reasoning (`thinkingLevel`: `low`, `medium`, `high`; `minimal` is not supported). | Uses `thinkingLevel` to control thinking depth with settings like `minimal`, `low`, `medium`, and `high`. Defaults to `minimal` to optimize for lowest latency. See [Thinking in the Live API](https://ai.google.dev/gemini-api/docs/live-api/thinking). |
| **[Receiving response](https://ai.google.dev/api/live#bidigeneratecontentservercontent)** | A single server event can contain multiple content parts simultaneously. | A single server event can contain multiple content parts simultaneously. When asynchronous reasoning is active, `turnComplete: true` does not indicate an idle session; use `interaction_status` (`IN_PROGRESS` versus `IDLE`). | A single server event can contain multiple content parts simultaneously (for example, `inlineData` and transcript). Ensure your code processes all parts in each event to avoid missing content. |
| **[Client content](https://ai.google.dev/gemini-api/docs/live-api/capabilities#incremental-updates)** | `send_client_content` is supported throughout the entire session lifecycle with explicit roles (`user` or `model`). `turn_complete=true` unconditionally interrupts generation. | `send_client_content` is supported throughout the entire session lifecycle with explicit roles (`user` or `model`). `turn_complete=true` unconditionally interrupts generation. | `send_client_content` is supported throughout the entire session lifecycle with explicit roles (`user` or `model`). `turn_complete=true` unconditionally interrupts generation. |
| **[Asynchronous function calling](https://ai.google.dev/gemini-api/docs/live-tools#async-function-calling)** (`behavior: NON_BLOCKING`) | Supported (default). Set `behavior: NON_BLOCKING` or use backwards-compatible blocking mode with `behavior: BLOCKING`. Function scheduling (`SILENT`, `WHEN_IDLE`, `INTERRUPTED`) is supported. | Supported (Async only). Only `NON_BLOCKING` execution is supported. Blocking mode and function scheduling are not supported. | Not supported. Function calling is sequential only. The model will not start responding until you've sent the tool response. |

To migrate to Gemini 3.8 Live, see the
[migration guide](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live#migrating).
To learn more about Thinking, see the
[Thinking guide](https://ai.google.dev/gemini-api/docs/live-api/thinking) and the
[upgrade guide](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live-extended-thinking#upgrading).

## Establishing a connection

The following example shows how to create a connection with an API key:

### Python

    import asyncio
    from google import genai

    client = genai.Client()

    model = "gemini-3.8-live"
    config = {"response_modalities": ["AUDIO"]}

    async def main():
        async with client.aio.live.connect(model=model, config=config) as session:
            print("Session started")
            # Send content...

    if __name__ == "__main__":
        asyncio.run(main())

### JavaScript

    import { GoogleGenAI, Modality } from '@google/genai';

    const ai = new GoogleGenAI({});
    const model = 'gemini-3.8-live';
    const config = { responseModalities: [Modality.AUDIO] };

    async function main() {

      const session = await ai.live.connect({
        model: model,
        callbacks: {
          onopen: function () {
            console.debug('Opened');
          },
          onmessage: function (message) {
            console.debug(message);
          },
          onerror: function (e) {
            console.debug('Error:', e.message);
          },
          onclose: function (e) {
            console.debug('Close:', e.reason);
          },
        },
        config: config,
      });

      console.debug("Session started");
      // Send content...

      session.close();
    }

    main();

## Interaction modalities

The following sections provide examples and supporting context for the different
input and output modalities available in Live API.

### Sending audio

Audio needs to be sent as raw PCM data (raw 16-bit PCM audio, 16kHz, little-endian).

### Python

    # Assuming 'chunk' is your raw PCM audio bytes
    await session.send_realtime_input(
        audio=types.Blob(
            data=chunk,
            mime_type="audio/pcm;rate=16000"
        )
    )

### JavaScript

    // Assuming 'chunk' is a Buffer of raw PCM audio
    session.sendRealtimeInput({
      audio: {
        data: chunk.toString('base64'),
        mimeType: 'audio/pcm;rate=16000'
      }
    });

### Audio formats

Audio data in the Live API is always raw, little-endian,
16-bit PCM. Audio output always uses a sample rate of 24kHz. Input audio
is natively 16kHz, but the Live API will resample if needed
so any sample rate can be sent. To convey the sample rate of input audio, set
the MIME type of each audio-containing [Blob](https://ai.google.dev/api/caching#Blob) to a value
like `audio/pcm;rate=16000`.

### Receiving audio

The model's audio responses are received as chunks of data.

### Python

    async for response in session.receive():
        if response.server_content and response.server_content.model_turn:
            for part in response.server_content.model_turn.parts:
                if part.inline_data:
                    audio_data = part.inline_data.data
                    # Process or play the audio data

### JavaScript

    // Inside the onmessage callback
    const content = response.serverContent;
    if (content?.modelTurn?.parts) {
      for (const part of content.modelTurn.parts) {
        if (part.inlineData) {
          const audioData = part.inlineData.data;
          // Process or play audioData (base64 encoded string)
        }
      }
    }

### Sending text

Text can be sent using `send_realtime_input` (Python) or `sendRealtimeInput` (JavaScript).

### Python

    await session.send_realtime_input(text="Hello, how are you?")

### JavaScript

    session.sendRealtimeInput({
      text: 'Hello, how are you?'
    });

### Sending video

Video frames are sent as individual images (e.g., JPEG or PNG) at a specific frame rate (max 1 frame per second).

### Python

    # Assuming 'frame' is your JPEG-encoded image bytes
    await session.send_realtime_input(
        video=types.Blob(
            data=frame,
            mime_type="image/jpeg"
        )
    )

### JavaScript

    // Assuming 'frame' is a Buffer of JPEG-encoded image data
    session.sendRealtimeInput({
      video: {
        data: frame.toString('base64'),
        mimeType: 'image/jpeg'
      }
    });

#### Incremental content updates

Use incremental updates to send text input, establish session context, or
restore session context. For short contexts you can send turn-by-turn
interactions to represent the exact sequence of events:

> [!NOTE]
> **Note:** The Live API supports `send_client_content` throughout the entire session lifecycle with explicit roles (`user` and `model`).

### Python

    turns = [
        {"role": "user", "parts": [{"text": "What is the capital of France?"}]},
        {"role": "model", "parts": [{"text": "Paris"}]},
    ]

    await session.send_client_content(turns=turns, turn_complete=False)

    turns = [{"role": "user", "parts": [{"text": "What is the capital of Germany?"}]}]

    await session.send_client_content(turns=turns, turn_complete=True)

### JavaScript

    let inputTurns = [
      { "role": "user", "parts": [{ "text": "What is the capital of France?" }] },
      { "role": "model", "parts": [{ "text": "Paris" }] },
    ]

    session.sendClientContent({ turns: inputTurns, turnComplete: false })

    inputTurns = [{ "role": "user", "parts": [{ "text": "What is the capital of Germany?" }] }]

    session.sendClientContent({ turns: inputTurns, turnComplete: true })

For longer contexts it's recommended to provide a single message summary to free
up the context window for subsequent interactions. See [Session Resumption](https://ai.google.dev/gemini-api/docs/live-session#session-resumption) for another method for
loading session context.

### Audio transcriptions

In addition to the model response, you can also receive transcriptions of
both the audio output and the audio input.

To enable transcription of the model's audio output, send
`output_audio_transcription` in the setup config. The transcription language is
inferred from the model's response.

### Python

    import asyncio
    from google import genai
    from google.genai import types

    client = genai.Client()
    model = "gemini-3.8-live"

    config = {
        "response_modalities": ["AUDIO"],
        "output_audio_transcription": {}
    }

    async def main():
        async with client.aio.live.connect(model=model, config=config) as session:
            message = "Hello? Gemini are you there?"

            await session.send_client_content(
                turns={"role": "user", "parts": [{"text": message}]}, turn_complete=True
            )

            async for response in session.receive():
                if response.server_content.model_turn:
                    print("Model turn:", response.server_content.model_turn)
                if response.server_content.output_transcription:
                    print("Transcript:", response.server_content.output_transcription.text)

    if __name__ == "__main__":
        asyncio.run(main())

### JavaScript

    import { GoogleGenAI, Modality } from '@google/genai';

    const ai = new GoogleGenAI({});
    const model = 'gemini-3.8-live';

    const config = {
      responseModalities: [Modality.AUDIO],
      outputAudioTranscription: {}
    };

    async function live() {
      const responseQueue = [];

      async function waitMessage() {
        let done = false;
        let message = undefined;
        while (!done) {
          message = responseQueue.shift();
          if (message) {
            done = true;
          } else {
            await new Promise((resolve) => setTimeout(resolve, 100));
          }
        }
        return message;
      }

      async function handleTurn() {
        const turns = [];
        let done = false;
        while (!done) {
          const message = await waitMessage();
          turns.push(message);
          if (message.serverContent && message.serverContent.turnComplete) {
            done = true;
          }
        }
        return turns;
      }

      const session = await ai.live.connect({
        model: model,
        callbacks: {
          onopen: function () {
            console.debug('Opened');
          },
          onmessage: function (message) {
            responseQueue.push(message);
          },
          onerror: function (e) {
            console.debug('Error:', e.message);
          },
          onclose: function (e) {
            console.debug('Close:', e.reason);
          },
        },
        config: config,
      });

      const inputTurns = 'Hello how are you?';
      session.sendClientContent({ turns: inputTurns });

      const turns = await handleTurn();

      for (const turn of turns) {
        if (turn.serverContent && turn.serverContent.outputTranscription) {
          console.debug('Received output transcription: %s\n', turn.serverContent.outputTranscription.text);
        }
      }

      session.close();
    }

    async function main() {
      await live().catch((e) => console.error('got error', e));
    }

    main();

To enable transcription of the model's audio input, send
`input_audio_transcription` in setup config.

### Python

    import asyncio
    from pathlib import Path
    from google import genai
    from google.genai import types

    client = genai.Client()
    model = "gemini-3.8-live"

    config = {
        "response_modalities": ["AUDIO"],
        "input_audio_transcription": {},
    }

    async def main():
        async with client.aio.live.connect(model=model, config=config) as session:
            audio_data = Path("16000.pcm").read_bytes()

            await session.send_realtime_input(
                audio=types.Blob(data=audio_data, mime_type='audio/pcm;rate=16000')
            )

            async for msg in session.receive():
                if msg.server_content.input_transcription:
                    print('Transcript:', msg.server_content.input_transcription.text)

    if __name__ == "__main__":
        asyncio.run(main())

### JavaScript

    import { GoogleGenAI, Modality } from '@google/genai';
    import * as fs from "node:fs";
    import pkg from 'wavefile';
    const { WaveFile } = pkg;

    const ai = new GoogleGenAI({});
    const model = 'gemini-3.8-live';

    const config = {
      responseModalities: [Modality.AUDIO],
      inputAudioTranscription: {}
    };

    async function live() {
      const responseQueue = [];

      async function waitMessage() {
        let done = false;
        let message = undefined;
        while (!done) {
          message = responseQueue.shift();
          if (message) {
            done = true;
          } else {
            await new Promise((resolve) => setTimeout(resolve, 100));
          }
        }
        return message;
      }

      async function handleTurn() {
        const turns = [];
        let done = false;
        while (!done) {
          const message = await waitMessage();
          turns.push(message);
          if (message.serverContent && message.serverContent.turnComplete) {
            done = true;
          }
        }
        return turns;
      }

      const session = await ai.live.connect({
        model: model,
        callbacks: {
          onopen: function () {
            console.debug('Opened');
          },
          onmessage: function (message) {
            responseQueue.push(message);
          },
          onerror: function (e) {
            console.debug('Error:', e.message);
          },
          onclose: function (e) {
            console.debug('Close:', e.reason);
          },
        },
        config: config,
      });

      // Send Audio Chunk
      const fileBuffer = fs.readFileSync("16000.wav");

      // Ensure audio conforms to API requirements (16-bit PCM, 16kHz, mono)
      const wav = new WaveFile();
      wav.fromBuffer(fileBuffer);
      wav.toSampleRate(16000);
      wav.toBitDepth("16");
      const base64Audio = wav.toBase64();

      // If already in correct format, you can use this:
      // const fileBuffer = fs.readFileSync("sample.pcm");
      // const base64Audio = Buffer.from(fileBuffer).toString('base64');

      session.sendRealtimeInput(
        {
          audio: {
            data: base64Audio,
            mimeType: "audio/pcm;rate=16000"
          }
        }
      );

      const turns = await handleTurn();
      for (const turn of turns) {
        if (turn.text) {
          console.debug('Received text: %s\n', turn.text);
        }
        else if (turn.data) {
          console.debug('Received inline data: %s\n', turn.data);
        }
        else if (turn.serverContent && turn.serverContent.inputTranscription) {
          console.debug('Received input transcription: %s\n', turn.serverContent.inputTranscription.text);
        }
      }

      session.close();
    }

    async function main() {
      await live().catch((e) => console.error('got error', e));
    }

    main();

### Change voice and language

[Native audio output](https://ai.google.dev/gemini-api/docs/live-api/capabilities#native-audio-output) models support any of the voices
available for our [Text-to-Speech (TTS)](https://ai.google.dev/gemini-api/docs/speech-generation#voices)
models. You can listen to all the voices in [AI Studio](https://aistudio.google.com/app/live).

To specify a voice, set the voice name within the `speechConfig` object as part
of the session configuration:

### Python

    config = {
        "response_modalities": ["AUDIO"],
        "speech_config": {
            "voice_config": {"prebuilt_voice_config": {"voice_name": "Kore"}}
        },
    }

### JavaScript

    const config = {
      responseModalities: [Modality.AUDIO],
      speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: "Kore" } } }
    };

> [!NOTE]
> **Note:** If you're using the `generateContent` API, the set of available voices is slightly different. See the [speech generation guide](https://ai.google.dev/gemini-api/docs/speech-generation#voices) for `generateContent` audio generation voices.

The Live API supports [multiple languages](https://ai.google.dev/gemini-api/docs/live-api/capabilities#supported-languages).
[Native audio output](https://ai.google.dev/gemini-api/docs/live-api/capabilities#native-audio-output) models automatically choose
the appropriate language and don't support explicitly setting the language
code.

## Native audio capabilities

Our latest models feature
[native audio output](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live),
which provides natural, realistic-sounding speech and improved multilingual
performance.

### Thinking

Gemini 3.8 Live Extended Thinking and Gemini 3.1 models use `thinkingLevel` to
control thinking depth. For `gemini-3.8-live`, `thinkingLevel` is not supported
and must be omitted in setup. Gemini 3.8 Live Extended Thinking supports `low`,
`medium`, and `high` (`minimal` is not supported). Gemini 3.1 models support
`minimal`, `low`, `medium`, and `high`. For more details, see
[Thinking in the Live API](https://ai.google.dev/gemini-api/docs/live-api/thinking).

### Python

    model = "gemini-3.8-live-extended-thinking"

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"]
        thinking_config=types.ThinkingConfig(
            thinking_level="low",
        )
    )

    async with client.aio.live.connect(model=model, config=config) as session:
        # Send audio input and receive audio

### JavaScript

    const model = 'gemini-3.8-live-extended-thinking';
    const config = {
      responseModalities: [Modality.AUDIO],
      thinkingConfig: {
        thinkingLevel: 'low',
      },
    };

    async function main() {

      const session = await ai.live.connect({
        model: model,
        config: config,
        callbacks: ...,
      });

      // Send audio input and receive audio

      session.close();
    }

    main();

Additionally, you can enable thought summaries by setting `includeThoughts` to
`true` in your configuration. See [thought summaries](https://ai.google.dev/gemini-api/docs/thinking#summaries)
for more info:

### Python

    model = "gemini-3.8-live-extended-thinking"

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"]
        thinking_config=types.ThinkingConfig(
            thinking_level="low",
            include_thoughts=True
        )
    )

### JavaScript

    const model = 'gemini-3.8-live-extended-thinking';
    const config = {
      responseModalities: [Modality.AUDIO],
      thinkingConfig: {
        thinkingLevel: 'low',
        includeThoughts: true,
      },
    };

### Affective dialog

This feature lets Gemini adapt its response style to the input expression and
tone.

> [!NOTE]
> **Note:** This feature is not supported in Gemini 3.1 Flash Live.

To use affective dialog, set the api version to `v1beta` and set
`enable_affective_dialog` to `true`in the setup message:

### Python

    client = genai.Client(http_options={"api_version": "v1beta"})

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        enable_affective_dialog=True
    )

### JavaScript

    const ai = new GoogleGenAI({ httpOptions: {"apiVersion": "v1beta"} });

    const config = {
      responseModalities: [Modality.AUDIO],
      enableAffectiveDialog: true
    };

### Proactive audio

When this feature is enabled, Gemini can proactively decide not to respond
if the content is not relevant.

> [!NOTE]
> **Note:** This feature is not supported in Gemini 3.1 Flash Live.

To use it, set the api version to `v1beta` and configure the `proactivity`
field in the setup message and set `proactive_audio` to `true`:

### Python

    client = genai.Client(http_options={"api_version": "v1beta"})

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        proactivity={'proactive_audio': True}
    )

### JavaScript

    const ai = new GoogleGenAI({ httpOptions: {"apiVersion": "v1beta"} });

    const config = {
      responseModalities: [Modality.AUDIO],
      proactivity: { proactiveAudio: true }
    }

## Live translation

The Live API supports real-time, low-latency translation of spoken conversations. This capability lets you build real-time voice-to-voice translation applications.

For more information and examples, see the [Live Translation guide](https://ai.google.dev/gemini-api/docs/live-api/live-translate).

## Voice Activity Detection (VAD)

Voice Activity Detection (VAD) allows the model to recognize when a person is
speaking. This is essential for creating natural conversations, as it allows a
user to interrupt the model at any time.

When VAD detects an interruption, the ongoing generation is canceled and
discarded. Only the information already sent to the client is retained in the
session history. The server then sends a [`BidiGenerateContentServerContent`](https://ai.google.dev/api/live#bidigeneratecontentservercontent) message to report the interruption.

The Gemini server then discards any pending function calls and sends a
`BidiGenerateContentServerContent` message with the IDs of the canceled calls.

### Python

    async for response in session.receive():
        if response.server_content.interrupted is True:
            # The generation was interrupted

            # If realtime playback is implemented in your application,
            # you should stop playing audio and clear queued playback here.

### JavaScript

    const turns = await handleTurn();

    for (const turn of turns) {
      if (turn.serverContent && turn.serverContent.interrupted) {
        // The generation was interrupted

        // If realtime playback is implemented in your application,
        // you should stop playing audio and clear queued playback here.
      }
    }

### Automatic VAD

By default, the model automatically performs VAD on
a continuous audio input stream. VAD can be configured with the
[`realtimeInputConfig.automaticActivityDetection`](https://ai.google.dev/api/live#RealtimeInputConfig.AutomaticActivityDetection)
field of the [setup configuration](https://ai.google.dev/api/live#BidiGenerateContentSetup).

When the audio stream is paused for more than a second (for example,
because the user switched off the microphone), an
[`audioStreamEnd`](https://ai.google.dev/api/live#BidiGenerateContentRealtimeInput.FIELDS.bool.BidiGenerateContentRealtimeInput.audio_stream_end)
event should be sent to flush any cached audio. The client can resume sending
audio data at any time.

### Python

    # example audio file to try:
    # URL = "https://storage.googleapis.com/generativeai-downloads/data/hello_are_you_there.pcm"
    # !wget -q $URL -O sample.pcm
    import asyncio
    from pathlib import Path
    from google import genai
    from google.genai import types

    client = genai.Client()
    model = "gemini-3.8-live"

    config = {"response_modalities": ["AUDIO"]}

    async def main():
        async with client.aio.live.connect(model=model, config=config) as session:
            audio_bytes = Path("sample.pcm").read_bytes()

            await session.send_realtime_input(
                audio=types.Blob(data=audio_bytes, mime_type="audio/pcm;rate=16000")
            )

            # if stream gets paused, send:
            # await session.send_realtime_input(audio_stream_end=True)

            async for response in session.receive():
                if response.text is not None:
                    print(response.text)

    if __name__ == "__main__":
        asyncio.run(main())

### JavaScript

    // example audio file to try:
    // URL = "https://storage.googleapis.com/generativeai-downloads/data/hello_are_you_there.pcm"
    // !wget -q $URL -O sample.pcm
    import { GoogleGenAI, Modality } from '@google/genai';
    import * as fs from "node:fs";

    const ai = new GoogleGenAI({});
    const model = 'gemini-3.8-live';
    const config = { responseModalities: [Modality.AUDIO] };

    async function live() {
      const responseQueue = [];

      async function waitMessage() {
        let done = false;
        let message = undefined;
        while (!done) {
          message = responseQueue.shift();
          if (message) {
            done = true;
          } else {
            await new Promise((resolve) => setTimeout(resolve, 100));
          }
        }
        return message;
      }

      async function handleTurn() {
        const turns = [];
        let done = false;
        while (!done) {
          const message = await waitMessage();
          turns.push(message);
          if (message.serverContent && message.serverContent.turnComplete) {
            done = true;
          }
        }
        return turns;
      }

      const session = await ai.live.connect({
        model: model,
        callbacks: {
          onopen: function () {
            console.debug('Opened');
          },
          onmessage: function (message) {
            responseQueue.push(message);
          },
          onerror: function (e) {
            console.debug('Error:', e.message);
          },
          onclose: function (e) {
            console.debug('Close:', e.reason);
          },
        },
        config: config,
      });

      // Send Audio Chunk
      const fileBuffer = fs.readFileSync("sample.pcm");
      const base64Audio = Buffer.from(fileBuffer).toString('base64');

      session.sendRealtimeInput(
        {
          audio: {
            data: base64Audio,
            mimeType: "audio/pcm;rate=16000"
          }
        }

      );

      // if stream gets paused, send:
      // session.sendRealtimeInput({ audioStreamEnd: true })

      const turns = await handleTurn();
      for (const turn of turns) {
        if (turn.text) {
          console.debug('Received text: %s\n', turn.text);
        }
        else if (turn.data) {
          console.debug('Received inline data: %s\n', turn.data);
        }
      }

      session.close();
    }

    async function main() {
      await live().catch((e) => console.error('got error', e));
    }

    main();

With `send_realtime_input`, the API will respond to audio automatically based
on VAD. While `send_client_content` adds messages to the model context in
order, `send_realtime_input` is optimized for responsiveness at the expense of
deterministic ordering.

### Automatic VAD configuration

For more control over the VAD activity, you can configure the following
parameters. See [API reference](https://ai.google.dev/api/live#automaticactivitydetection) for more
info.

### Python

    from google.genai import types

    config = {
        "response_modalities": ["AUDIO"],
        "realtime_input_config": {
            "automatic_activity_detection": {
                "disabled": False, # default
                "start_of_speech_sensitivity": types.StartSensitivity.START_SENSITIVITY_LOW,
                "end_of_speech_sensitivity": types.EndSensitivity.END_SENSITIVITY_LOW,
                "prefix_padding_ms": 20,
                "silence_duration_ms": 100,
            }
        }
    }

### JavaScript

    import { GoogleGenAI, Modality, StartSensitivity, EndSensitivity } from '@google/genai';

    const config = {
      responseModalities: [Modality.AUDIO],
      realtimeInputConfig: {
        automaticActivityDetection: {
          disabled: false, // default
          startOfSpeechSensitivity: StartSensitivity.START_SENSITIVITY_LOW,
          endOfSpeechSensitivity: EndSensitivity.END_SENSITIVITY_LOW,
          prefixPaddingMs: 20,
          silenceDurationMs: 100,
        }
      }
    };

### Hybrid VAD

Hybrid VAD combines the benefits of automatic VAD (robust speech start detection) and manual VAD (low-latency response finalization).

In this configuration:

1. **Automatic VAD remains enabled** on the server. The server automatically detects the start of user speech, using prefix padding to avoid clipping the beginning of utterances.
2. The client uses a **client-side VAD** to detect when the user stops speaking.
3. When the client-side VAD detects the end of speech, it sends an [`audio_stream_end`](https://ai.google.dev/api/live#BidiGenerateContentRealtimeInput.FIELDS.bool.BidiGenerateContentRealtimeInput.audio_stream_end) signal to the server.
4. The server treats the `audio_stream_end` signal as an immediate finalization prompt, bypassing the default server-side silence detection delay and returning the transcript and model response with minimal latency.
5. If the client-side VAD fails to trigger, the server-side VAD acts as a fallback to detect the end of speech.

Note that if the client-side VAD threshold is set too aggressively, it may cause
speech cutoffs. However, this approach prevents front-truncation issues which
might occur with manual VAD.

### Python

    # Set up with automatic VAD enabled (default)
    config = {
        "response_modalities": ["AUDIO"],
    }

    async with client.aio.live.connect(model=model, config=config) as session:
        # Send audio data normally
        await session.send_realtime_input(
            audio=types.Blob(data=audio_bytes, mime_type="audio/pcm;rate=16000")
        )

        # When client-side VAD detects the end of speech, send:
        await session.send_realtime_input(audio_stream_end=True)

### JavaScript

    // Set up with automatic VAD enabled (default)
    const config = {
      responseModalities: [Modality.AUDIO],
    };

    // Send audio data normally
    session.sendRealtimeInput({
      audio: {
        data: base64Audio,
        mimeType: "audio/pcm;rate=16000"
      }
    });

    // When client-side VAD detects the end of speech, send:
    session.sendRealtimeInput({ audioStreamEnd: true });

### Disable automatic VAD

Alternatively, the automatic VAD can be disabled by setting
`realtimeInputConfig.automaticActivityDetection.disabled` to `true` in the setup
message. In this configuration the client is responsible for detecting user
speech and sending
[`activityStart`](https://ai.google.dev/api/live#BidiGenerateContentRealtimeInput.FIELDS.BidiGenerateContentRealtimeInput.ActivityStart.BidiGenerateContentRealtimeInput.activity_start)
and [`activityEnd`](https://ai.google.dev/api/live#BidiGenerateContentRealtimeInput.FIELDS.BidiGenerateContentRealtimeInput.ActivityEnd.BidiGenerateContentRealtimeInput.activity_end)
messages at the appropriate times. An `audioStreamEnd` isn't sent in
this configuration. Instead, any interruption of the stream is marked by
an `activityEnd` message.

### Python

    config = {
        "response_modalities": ["AUDIO"],
        "realtime_input_config": {"automatic_activity_detection": {"disabled": True}},
    }

    async with client.aio.live.connect(model=model, config=config) as session:
        # ...
        await session.send_realtime_input(activity_start=types.ActivityStart())
        await session.send_realtime_input(
            audio=types.Blob(data=audio_bytes, mime_type="audio/pcm;rate=16000")
        )
        await session.send_realtime_input(activity_end=types.ActivityEnd())
        # ...

### JavaScript

    const config = {
      responseModalities: [Modality.AUDIO],
      realtimeInputConfig: {
        automaticActivityDetection: {
          disabled: true,
        }
      }
    };

    session.sendRealtimeInput({ activityStart: {} })

    session.sendRealtimeInput(
      {
        audio: {
          data: base64Audio,
          mimeType: "audio/pcm;rate=16000"
        }
      }

    );

    session.sendRealtimeInput({ activityEnd: {} })

### Understanding VAD parameters and their impact on quality

When using automatic VAD, two key parameters control how audio is
segmented into speech turns before being sent to the model:

- **`prefixPaddingMs`** : The amount of audio to include *before* speech is detected. This "look-back" ensures the model captures the full onset of speech, including the first syllable which may start before the VAD triggers. A value of `0` may cause the beginning of words to be clipped.
- **`silenceDurationMs`**: How long the server waits through silence before ending a speech turn. This determines how tolerant the system is of natural mid-sentence pauses (e.g., thinking, breathing, or clause boundaries).

#### Impact of `silenceDurationMs` on audio quality

The `silenceDurationMs` value directly affects the size and completeness
of audio chunks the model receives for processing:

- **Recommended (500ms--800ms):** Provides a good balance---the model receives complete, contextually rich audio chunks while keeping latency reasonable. The server's internal default is approximately 800ms.
- **Too low (e.g., 100ms--200ms):** The system ends speech turns during natural pauses, splitting a single utterance into multiple small audio fragments. The model receives these fragments individually, losing cross-fragment context and resulting in lower transcription and response quality.
- **Too high (e.g., 2000ms+):** The system waits a long time after the user stops speaking, increasing perceived latency before the model responds.

#### Best practices for manual (client-side) VAD

When you disable automatic VAD and manage `activityStart`/`activityEnd`
signals from your own client-side voice detection, be aware that the
server's built-in audio buffering mechanisms are bypassed. This means:

1. **No pre-speech buffer:** The server no longer prepends audio before the detected speech start. Your client should include sufficient audio context before sending `activityStart`.
2. **No silence tolerance:** The server acts immediately on your `activityEnd` signal with no additional wait. If your client-side VAD uses an aggressive end-of-speech threshold (e.g., 200ms of silence), speech may be cut off mid-sentence during natural pauses.

To preserve audio quality with manual VAD, use an end-of-speech silence
threshold of at least **500ms** in your client's voice activity detector.
Thresholds below this value often cause fragmented audio that degrades
transcription and model response quality.

## Token count

You can find the total number of consumed tokens in the
[usageMetadata](https://ai.google.dev/api/live#usagemetadata) field of the returned server message.

### Python

    async for message in session.receive():
        # The server will periodically send messages that include UsageMetadata.
        if message.usage_metadata:
            usage = message.usage_metadata
            print(
                f"Used {usage.total_token_count} tokens in total. Response token breakdown:"
            )
            for detail in usage.response_tokens_details:
                match detail:
                    case types.ModalityTokenCount(modality=modality, token_count=count):
                        print(f"{modality}: {count}")

### JavaScript

    const turns = await handleTurn();

    for (const turn of turns) {
      if (turn.usageMetadata) {
        console.debug('Used %s tokens in total. Response token breakdown:\n', turn.usageMetadata.totalTokenCount);

        for (const detail of turn.usageMetadata.responseTokensDetails) {
          console.debug('%s\n', detail);
        }
      }
    }

## Media resolution

You can specify the media resolution for the input media by setting the
`mediaResolution` field as part of the session configuration:

### Python

    from google.genai import types

    config = {
        "response_modalities": ["AUDIO"],
        "media_resolution": types.MediaResolution.MEDIA_RESOLUTION_LOW,
    }

### JavaScript

    import { GoogleGenAI, Modality, MediaResolution } from '@google/genai';

    const config = {
        responseModalities: [Modality.AUDIO],
        mediaResolution: MediaResolution.MEDIA_RESOLUTION_LOW,
    };

You can configure `mediaResolution` for multimodal sessions that include
audio, video, or image inputs. While `mediaResolution` adjusts the token
allocation per frame for visual inputs, audio streams are tokenized at a
fixed rate per second across all resolution settings. For more information,
see the [Media resolution](https://ai.google.dev/gemini-api/docs/media-resolution) guide.

## Limitations

Consider the following limitations of the Live API
when you plan your project.

### Response modalities

The native audio models only support \`AUDIO response modality. If you need the
model response as text, use the [output audio transcription](https://ai.google.dev/gemini-api/docs/live-api/capabilities#audio-transcription)
feature.

### Client authentication

The Live API only provides server-to-server authentication
by default. If you're implementing your Live API application
using a [client-to-server approach](https://ai.google.dev/gemini-api/docs/live#implementation-approach), you need to use
[ephemeral tokens](https://ai.google.dev/gemini-api/docs/ephemeral-tokens) to mitigate security
risks.

### Session duration

Audio-only sessions are limited to 15 minutes,
and audio plus video sessions are limited to 2 minutes.
However, you can configure different [session management techniques](https://ai.google.dev/gemini-api/docs/live-session) for unlimited extensions on session duration.

### Context window

A session has a context window limit of:

- 128k tokens for [native audio output](https://ai.google.dev/gemini-api/docs/live-api/capabilities#native-audio-output) models
- 32k tokens for other Live API models

## Supported languages

Live API supports the following 99 languages.

> [!NOTE]
> **Note:** [Native audio output](https://ai.google.dev/gemini-api/docs/live-api/capabilities#native-audio-output) models can switch between languages naturally during conversation. You can also restrict the languages it speaks in by specifying it in the system instructions.

| Language | BCP-47 Code | Language | BCP-47 Code |
|---|---|---|---|
| Afrikaans | `af` | Latvian | `lv` |
| Akan | `ak` | Lithuanian | `lt` |
| Albanian | `sq` | Macedonian | `mk` |
| Amharic | `am` | Malay | `ms` |
| Arabic | `ar` | Malayalam | `ml` |
| Armenian | `hy` | Maltese | `mt` |
| Assamese | `as` | Maori | `mi` |
| Azerbaijani | `az` | Marathi | `mr` |
| Basque | `eu` | Mongolian | `mn` |
| Belarusian | `be` | Nepali | `ne` |
| Bengali | `bn` | Norwegian | `no`, `nb` |
| Bosnian | `bs` | Odia | `or` |
| Bulgarian | `bg` | Oromo | `om` |
| Burmese | `my` | Pashto | `ps` |
| Catalan | `ca` | Persian | `fa` |
| Cebuano | `ceb` | Polish | `pl` |
| Chinese (Simplified) | `zh-Hans` | Portuguese (Brazil) | `pt-BR` |
| Chinese (Traditional) | `zh-Hant` | Portuguese (Portugal) | `pt-PT` |
| Croatian | `hr` | Punjabi | `pa` |
| Czech | `cs` | Quechua | `qu` |
| Danish | `da` | Romanian | `ro` |
| Dutch | `nl` | Romansh | `rm` |
| English | `en` | Russian | `ru` |
| Estonian | `et` | Serbian | `sr` |
| Faroese | `fo` | Sindhi | `sd` |
| Filipino | `fil` | Sinhala | `si` |
| Finnish | `fi` | Slovak | `sk` |
| French | `fr` | Slovenian | `sl` |
| Galician | `gl` | Somali | `so` |
| Georgian | `ka` | Southern Sotho | `st` |
| German | `de` | Spanish | `es` |
| Greek | `el` | Swahili | `sw` |
| Gujarati | `gu` | Swedish | `sv` |
| Hausa | `ha` | Tajik | `tg` |
| Hebrew | `he` | Tamil | `ta` |
| Hindi | `hi` | Telugu | `te` |
| Hungarian | `hu` | Thai | `th` |
| Icelandic | `is` | Tswana | `tn` |
| Indonesian | `id` | Turkish | `tr` |
| Irish | `ga` | Turkmen | `tk` |
| Italian | `it` | Ukrainian | `uk` |
| Japanese | `ja` | Urdu | `ur` |
| Kannada | `kn` | Uzbek | `uz` |
| Kazakh | `kk` | Vietnamese | `vi` |
| Khmer | `km` | Welsh | `cy` |
| Kinyarwanda | `rw` | Western Frisian | `fy` |
| Korean | `ko` | Wolof | `wo` |
| Kurdish | `ku` | Yoruba | `yo` |
| Kyrgyz | `ky` | Zulu | `zu` |
| Lao | `lo` |   |   |

## What's next

- Read the [Tool Use](https://ai.google.dev/gemini-api/docs/live-tools) and [Session Management](https://ai.google.dev/gemini-api/docs/live-session) guides for essential information on using the Live API effectively.
- Try the Live API in [Google AI Studio](https://aistudio.google.com/app/live).
- For more info about the Live API models, see the [Gemini 3.8 Live](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live) and [Gemini 3.8 Live Extended Thinking](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live-extended-thinking) model pages.
- Try more examples in the [Live API cookbook](https://colab.research.google.com/github/google-gemini/cookbook/blob/main/quickstarts/Get_started_LiveAPI.ipynb), the [Live API Tools cookbook](https://colab.research.google.com/github/google-gemini/cookbook/blob/main/quickstarts/Get_started_LiveAPI_tools.ipynb), and the [Live API Get Started script](https://github.com/google-gemini/cookbook/blob/main/quickstarts/Get_started_LiveAPI.py).