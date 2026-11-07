> ## Documentation Index
> Fetch the complete documentation index at: https://docs.rime.ai/llms.txt
> Use this file to discover all available pages before exploring further.

# Talk to Prism over WebSocket

> Send Prism a recorded question over a WebSocket in Python or Node.js, without the Rime SDK, and listen to the spoken answer.

In this quickstart, you'll send Prism a pre-recorded question over a secure WebSocket, without the Rime SDK, and listen to its answer in `reply.wav`. By the end, you'll have a one-file script in Python or Node.js you can port to any language with a WebSocket client.

Prism answers the phone for a made-up cafe, and a recorded caller asks when the cafe closes today. Take this path when your backend's language has no Rime SDK, or you want to handle Prism's JSON events yourself.

> [!TIP]
>
> **Working in Python or Node.js?** In our [SDK quickstart](https://docs.rime.ai/docs/prism/quickstart.md), you talk to Prism through your microphone, with your own instructions.

## What you'll need

* A Rime API key. If you don't have one yet, [create one](https://docs.rime.ai/docs/api-authentication.md).
* [uv](https://docs.astral.sh/uv/getting-started/installation/) for Python, or Node.js 22 or later.
* Your computer or a server to run the script. A browser can't connect directly, because Prism checks your API key in the `Authorization` header, which the browser `WebSocket` API can't set.

## Build it step by step

**1. Create the project and install a WebSocket client**

Any WebSocket client works, as long as it can set headers on the connection request. These commands pin `websockets` 17.2 for Python and `ws` 8.22.0 for Node.js.

> [tab] Python
>
> Create a project and add the `websockets` package:
>
> ```bash theme={null}
> uv init --python 3.12 rime-prism-websocket
> cd rime-prism-websocket
> uv add "websockets==17.2"
> ```

> [tab] Node.js
>
> Create a project and add the `ws` package:
>
> ```bash theme={null}
> mkdir rime-prism-websocket
> cd rime-prism-websocket
> npm init -y
> npm install --save-exact ws@8.22.0
> ```

**2. Set your API key**

The script reads your key from `RIME_API_KEY` and sends it as `Authorization: Bearer YOUR_API_KEY` when it connects. Set it in the terminal where you'll run the script:

> [tab] macOS and Linux
>
> ```bash theme={null}
> export RIME_API_KEY="YOUR_API_KEY"
> ```

> [tab] Windows PowerShell
>
> ```powershell theme={null}
> $env:RIME_API_KEY = "YOUR_API_KEY"
> ```

**3. Download the sample question**

Your caller is a 3-second recording made with Rime text-to-speech, asking, "Hi there! I was just wondering, what time do you close today?" This command saves it to your project folder:

> [tab] macOS and Linux
>
> ```bash theme={null}
> curl -fsSLO https://docs.rime.ai/audio/prism/question.wav && tail -c +45 question.wav > question.pcm
> ```

> [tab] Windows PowerShell
>
> ```powershell theme={null}
> curl.exe -fsSLO https://docs.rime.ai/audio/prism/question.wav
> $wav = [IO.File]::ReadAllBytes("$PWD\question.wav")
> [IO.File]::WriteAllBytes("$PWD\question.pcm", [byte[]]$wav[44..($wav.Length - 1)])
> ```

You should now have `question.wav`, and `question.pcm`, the same audio without its 44-byte WAV header. That's the input format Prism accepts: raw 16-bit samples at 16 kHz, mono. To hear the question first, open [question.wav](https://docs.rime.ai/audio/prism/question.wav) in your browser.

To ask your own question, record it in English without pausing partway through. Prism ends the turn at a long pause, so a mid-sentence pause splits your question into two turns. Convert it to 16 kHz mono PCM16 with [FFmpeg](https://ffmpeg.org/download.html). This command reads `recording.mp3` and writes `recording.pcm`:

```bash theme={null}
ffmpeg -i recording.mp3 -ac 1 -ar 16000 -c:a pcm_s16le -f s16le recording.pcm
```

Run the script with `recording.pcm` in place of `question.pcm`.

**4. Save the script**

The script prints when Prism hears the caller start and stop, prints the reply text, and saves the reply audio to `reply.wav`. Save it in your project folder:

> [tab] Python
>
> ```python ask.py theme={null}
> import asyncio
> import base64
> import json
> import os
> import sys
> import wave
>
> import websockets
>
> URL = "wss://prism.api.rime.ai/v1/realtime"
> INSTRUCTIONS = (
>     "You answer the phone for Juniper Cafe. It's open from 8 a.m. to 4 p.m. "
>     "every day. Answer in one short sentence."
> )
> FRAME = 1280  # 40 ms of 16 kHz mono PCM16
>
>
> async def send_call_audio(socket, question):
>     # Send the question at speaking pace, then silence, as a live call would.
>     offset = 0
>     while True:
>         frame = question[offset : offset + FRAME].ljust(FRAME, b"\0")
>         audio = base64.b64encode(frame).decode()
>         await socket.send(json.dumps({"type": "input_audio_buffer.append", "audio": audio}))
>         offset += FRAME
>         await asyncio.sleep(0.04)
>
>
> async def read_reply(socket, question):
>     audio = bytearray()
>     sending = None
>     try:
>         async for message in socket:
>             event = json.loads(message)
>             kind = event["type"]
>             if kind == "session.updated":
>                 # Prism refuses audio sent before the session is set up.
>                 sending = asyncio.create_task(send_call_audio(socket, question))
>             elif kind == "input_audio_buffer.speech_started":
>                 print("Caller started speaking")
>             elif kind == "input_audio_buffer.speech_stopped":
>                 print("Caller stopped speaking")
>             elif kind == "response.created":
>                 print("Prism: ", end="")
>             elif kind == "response.text.delta":
>                 print(event["delta"], end="", flush=True)
>             elif kind == "response.audio.delta":
>                 audio += base64.b64decode(event["delta"])
>             elif kind == "error":
>                 error = event["error"]
>                 raise RuntimeError(f"{error['code']}: {error['message']}")
>             elif kind == "response.done":
>                 print()
>                 status = event["response"]["status"]
>                 if status != "completed":
>                     reason = event["response"]["status_details"]["reason"]
>                     raise RuntimeError(f"Reply {status}: {reason}")
>                 return audio
>     finally:
>         if sending:
>             sending.cancel()
>     raise ConnectionError("The session closed before the reply ended")
>
>
> async def main(path):
>     with open(path, "rb") as audio:
>         question = audio.read()
>     headers = {"Authorization": f"Bearer {os.environ['RIME_API_KEY']}"}
>     try:
>         async with (
>             asyncio.timeout(60) as deadline,
>             websockets.connect(URL, additional_headers=headers) as socket,
>         ):
>             await socket.send(json.dumps({
>                 "type": "session.update",
>                 "event_id": "evt_setup",  # Comes back in any error about this message
>                 "session": {"voice": "aurora", "instructions": INSTRUCTIONS},
>             }))
>             reply = await read_reply(socket, question)
>     except TimeoutError:
>         if deadline.expired():
>             raise TimeoutError("No reply within 60 seconds") from None
>         raise
>     with wave.open("reply.wav", "wb") as wav:
>         wav.setnchannels(1)
>         wav.setsampwidth(2)
>         wav.setframerate(24000)  # Prism replies in 24 kHz mono PCM16
>         wav.writeframes(reply)
>     print(f"Saved {len(reply) / 48000:.1f} seconds of audio to reply.wav")
>
>
> asyncio.run(main(sys.argv[1]))
> ```

> [tab] Node.js
>
> ```javascript ask.mjs theme={null}
> import { on } from "node:events";
> import { readFileSync, writeFileSync } from "node:fs";
> import WebSocket from "ws";
>
> const URL = "wss://prism.api.rime.ai/v1/realtime";
> const INSTRUCTIONS =
>   "You answer the phone for Juniper Cafe. It's open from 8 a.m. to 4 p.m. " +
>   "every day. Answer in one short sentence.";
> const FRAME = 1280; // 40 ms of 16 kHz mono PCM16
>
> function sendCallAudio(socket, question) {
>   // Send the question at speaking pace, then silence, as a live call would.
>   let offset = 0;
>   return setInterval(() => {
>     const frame = Buffer.alloc(FRAME);
>     question.subarray(offset, offset + FRAME).copy(frame);
>     const audio = frame.toString("base64");
>     socket.send(JSON.stringify({ type: "input_audio_buffer.append", audio }));
>     offset += FRAME;
>   }, 40);
> }
>
> async function readReply(socket, question) {
>   const audio = [];
>   let sending;
>   try {
>     for await (const [message] of on(socket, "message", { close: ["close"] })) {
>       const event = JSON.parse(message);
>       switch (event.type) {
>         case "session.updated":
>           // Prism refuses audio sent before the session is set up.
>           sending = sendCallAudio(socket, question);
>           break;
>         case "input_audio_buffer.speech_started":
>           console.log("Caller started speaking");
>           break;
>         case "input_audio_buffer.speech_stopped":
>           console.log("Caller stopped speaking");
>           break;
>         case "response.created":
>           process.stdout.write("Prism: ");
>           break;
>         case "response.text.delta":
>           process.stdout.write(event.delta);
>           break;
>         case "response.audio.delta":
>           audio.push(Buffer.from(event.delta, "base64"));
>           break;
>         case "error":
>           throw new Error(`${event.error.code}: ${event.error.message}`);
>         case "response.done": {
>           console.log();
>           const { status, status_details } = event.response;
>           if (status !== "completed") {
>             throw new Error(`Reply ${status}: ${status_details.reason}`);
>           }
>           return Buffer.concat(audio);
>         }
>       }
>     }
>   } finally {
>     clearInterval(sending);
>   }
>   throw new Error("The session closed before the reply ended");
> }
>
> // Prism replies in 24 kHz mono PCM16. A 44-byte header makes it a WAV file.
> function toWav(pcm) {
>   const header = Buffer.alloc(44);
>   header.write("RIFF", 0);
>   header.writeUInt32LE(36 + pcm.length, 4);
>   header.write("WAVEfmt ", 8);
>   header.writeUInt32LE(16, 16);
>   header.writeUInt16LE(1, 20); // PCM
>   header.writeUInt16LE(1, 22); // mono
>   header.writeUInt32LE(24000, 24); // samples per second
>   header.writeUInt32LE(48000, 28); // bytes per second
>   header.writeUInt16LE(2, 32);
>   header.writeUInt16LE(16, 34);
>   header.write("data", 36);
>   header.writeUInt32LE(pcm.length, 40);
>   return Buffer.concat([header, pcm]);
> }
>
> const question = readFileSync(process.argv[2]);
> const socket = new WebSocket(URL, {
>   headers: { Authorization: `Bearer ${process.env.RIME_API_KEY}` },
> });
> socket.on("open", () => {
>   socket.send(
>     JSON.stringify({
>       type: "session.update",
>       event_id: "evt_setup", // Comes back in any error about this message
>       session: { voice: "aurora", instructions: INSTRUCTIONS },
>     }),
>   );
> });
> let timedOut = false;
> const deadline = setTimeout(() => {
>   timedOut = true;
>   socket.terminate();
> }, 60_000);
> try {
>   const reply = await readReply(socket, question);
>   writeFileSync("reply.wav", toWav(reply));
>   console.log(`Saved ${(reply.length / 48000).toFixed(1)} seconds of audio to reply.wav`);
> } catch (error) {
>   throw timedOut ? new Error("No reply within 60 seconds") : error;
> } finally {
>   clearTimeout(deadline);
>   socket.close();
> }
> ```

The instructions give Prism one fact you can check by ear: Juniper Cafe closes at 4 p.m. Each message is one JSON object, and audio is base64 in both directions. The script stops when `response.done` ends the reply, or after 60 seconds.

**5. Run it and listen**

Run the script with the question file:

> [tab] Python
>
> ```bash theme={null}
> uv run ask.py question.pcm
> ```

> [tab] Node.js
>
> ```bash theme={null}
> node ask.mjs question.pcm
> ```

After a few seconds, you should see output like this:

```text theme={null}
Caller started speaking
Caller stopped speaking
Prism: We close at 4 p.m. every day.
Saved 2.9 seconds of audio to reply.wav
```

The first two lines come from `input_audio_buffer.speech_started` and `input_audio_buffer.speech_stopped`. Prism started its reply only after it found the end of the caller's turn. The `Prism:` line is the reply text, printed one `response.text.delta` at a time. The words and audio length change from run to run.

Now open `reply.wav` in an audio player. You should hear Prism say the cafe closes at 4 p.m. If the script doesn't work, here's where to look:

* **The script stops with an error:** find its code in [Errors and limits](https://docs.rime.ai/docs/prism/errors.md). In Python, `KeyError: 'RIME_API_KEY'` means the variable isn't set in your terminal. In Node.js, a missing variable gives `Unexpected server response: 401`, because the script sends `Bearer undefined`.
* **Prism refuses the connection:** the HTTP status in the error tells you why. [Upgrade refusals](https://docs.rime.ai/api-reference/prism/websocket.md#upgrade-refusals) lists each status.
* **Nothing prints until `No reply within 60 seconds`:** check that the audio is 16 kHz mono PCM16.

**6. Try another voice**

The script uses `aurora`, one of four Prism voices, and [Choose a voice](https://docs.rime.ai/docs/prism/sessions.md#choose-a-voice) describes the others: `wawona`, `brando`, and `astra`. Change the voice in the script's `session.update` to `wawona`, and run it on the same question again:

> [tab] Python
>
> ```python theme={null}
> "session": {"voice": "wawona", "instructions": INSTRUCTIONS},
> ```
>
> ```bash theme={null}
> uv run ask.py question.pcm
> ```

> [tab] Node.js
>
> ```javascript theme={null}
> session: { voice: "wawona", instructions: INSTRUCTIONS },
> ```
>
> ```bash theme={null}
> node ask.mjs question.pcm
> ```

You should see output like this:

```text theme={null}
Caller started speaking
Caller stopped speaking
Prism: We close at 4 p.m.
Saved 1.4 seconds of audio to reply.wav
```

The closing time is the same, but you'll hear a higher voice in `reply.wav`. This script sets the voice and instructions once. To change them during a conversation, send another [`session.update`](https://docs.rime.ai/api-reference/prism/websocket#session-update), and the next reply uses the new settings.

## How it works

The script behaves like a live call, so two things matter:

* **Order in the first messages:** it sends `session.update` as soon as the connection opens. It holds the audio until `session.updated` arrives, because Prism refuses audio sent before it accepts the first update.
* **The pace of a microphone:** it streams the recording in real time, a 40 ms chunk every 40 ms, and keeps sending silence after the question ends. The silence matters, because Prism finds the end of the caller's turn by itself.

Here's each step and the event behind it:

| Step | Event |
| - | - |
| Open the connection with your key | A WebSocket upgrade with `Authorization: Bearer`, as [Connect](https://docs.rime.ai/api-reference/prism/websocket.md#connect) describes |
| Set the voice and instructions | Send [`session.update`](https://docs.rime.ai/api-reference/prism/websocket#session-update) |
| Wait until Prism accepts them | Receive [`session.updated`](https://docs.rime.ai/api-reference/prism/websocket#session-updated) |
| Stream the question, then silence | Send [`input_audio_buffer.append`](https://docs.rime.ai/api-reference/prism/websocket#input_audio_buffer-append) every 40 ms |
| Show when the caller starts and stops | Receive [`input_audio_buffer.speech_started`](https://docs.rime.ai/api-reference/prism/websocket#input_audio_buffer-speech_started) and [`input_audio_buffer.speech_stopped`](https://docs.rime.ai/api-reference/prism/websocket#input_audio_buffer-speech_stopped) |
| Start the `Prism:` line | Receive [`response.created`](https://docs.rime.ai/api-reference/prism/websocket#response-created) |
| Print the reply text | Receive [`response.text.delta`](https://docs.rime.ai/api-reference/prism/websocket#response-text-delta) |
| Save the reply audio | Receive [`response.audio.delta`](https://docs.rime.ai/api-reference/prism/websocket#response-audio-delta), base64 of 24 kHz mono PCM16 |
| Stop when the reply ends | Receive [`response.done`](https://docs.rime.ai/api-reference/prism/websocket#response-done), and check that its `status` is `completed` |
| Stop on a refusal or failure | Receive [`error`](https://docs.rime.ai/api-reference/prism/websocket#error), and report its `code` |

Prism sends a few other events too, such as `session.created`, which comes first, and the caller's transcript. The script ignores them, and so can a first port.

## Next steps

Now that Prism answers a recording, you can build toward a live call:

* [Stop playback when the caller interrupts](https://docs.rime.ai/docs/prism/live-conversations.md), and report how much the caller heard. The [WebSocket reference](https://docs.rime.ai/api-reference/prism/websocket.md#rime-sdk-steps-as-websocket-events) lists the event for each step.
* [Let Prism ask your backend for data](https://docs.rime.ai/docs/prism/tools.md) it doesn't have, such as Saturday's opening hours.
* [Run the complete example](https://docs.rime.ai/api-reference/prism/websocket.md#complete-example), a Python client that adds a tool call to the same cafe conversation.
* [Write instructions that Prism follows](https://docs.rime.ai/docs/prism/prompting.md), starting with rules for speech.


This documentation is built and hosted on [Mintlify](https://mintlify.com), a developer documentation platform.