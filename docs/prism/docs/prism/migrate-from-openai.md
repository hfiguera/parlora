> ## Documentation Index
> Fetch the complete documentation index at: https://docs.rime.ai/llms.txt
> Use this file to discover all available pages before exploring further.

# Move from OpenAI Realtime to Prism

> Move a voice agent from OpenAI Realtime to Prism, whether it connects over a WebSocket, through LiveKit Agents or Pipecat, or with OpenAI's SDK.

Prism uses the event names and message shapes of the OpenAI Realtime beta interface. So your agent keeps its conversation logic, instructions, and tools when it moves, and most of its code stays as it is. Pick the path that matches how your agent connects today:

| Your agent today | What to do |
| - | - |
| A WebSocket client on your backend | [Change four things](#move-a-websocket-client) |
| LiveKit Agents with the OpenAI plugin | [Swap the model](#move-a-livekit-agent) |
| Pipecat with OpenAI Realtime | [Use the Rime service and its aggregator pair](#move-a-pipecat-agent) |
| OpenAI's SDK, WebRTC in the browser, or SIP | Connect from your backend with the [Rime SDK](#switch-to-the-rime-sdk), or bring calls in through [LiveKit](#move-a-livekit-agent) |

## Move a WebSocket client

The code that sends audio, tool results, cancels, and playback reports stays the same. Change these four things:

**1. Point the client at Prism**

Use Prism's address, and send your Rime API key in the same `Authorization` header. If you don't have a key yet, [create one](https://docs.rime.ai/docs/api-authentication.md).

```python OpenAI theme={null}
url = "wss://api.openai.com/v1/realtime?model=gpt-realtime"
headers = {
    "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}",
    "OpenAI-Beta": "realtime=v1",
}
```

```python Prism theme={null}
url = "wss://prism.api.rime.ai/v1/realtime"
headers = {"Authorization": f"Bearer {os.environ['RIME_API_KEY']}"}
```

Connect from your backend, because Prism has no ephemeral keys for browsers or phones.

**2. Trim the session settings**

Keep `instructions` and `tools`, and choose a Prism voice. Remove the settings that Prism handles itself, such as transcription, audio formats, and `temperature`. Prism also finds the turns, so keep only `interrupt_response` and `eagerness` in `turn_detection`:

```json theme={null}
{
  "type": "session.update",
  "event_id": "evt_setup",
  "session": {
    "voice": "aurora",
    "instructions": "You answer the phone for Juniper Cafe. Call get_opening_hours before you answer a question about opening hours. Answer in one short sentence.",
    "tools": [
      {
        "type": "function",
        "name": "get_opening_hours",
        "description": "Today's opening hours for Juniper Cafe.",
        "parameters": { "type": "object", "properties": {} }
      }
    ],
    "turn_detection": { "interrupt_response": true, "eagerness": "auto" }
  }
}
```

If Prism refuses a field, the error's `param` names it. The [WebSocket reference](https://docs.rime.ai/api-reference/prism/websocket.md#differences-from-openai-realtime) says what happens to each OpenAI field.

**3. Send the caller's audio at 16 kHz**

Prism replies at 24 kHz, as OpenAI does, but takes the caller's audio as PCM16 at 16 kHz, mono. Resample the caller's audio before you append it, and keep streaming it for the whole call, silence included.

**4. Add a cause to the replies you start**

On Prism, every `response.create` says why it asks for a reply. The most common one is the reply after a tool result:

```json OpenAI theme={null}
{ "type": "response.create" }
```

```json Prism theme={null}
{
  "type": "response.create",
  "event_id": "evt_continue",
  "response": {
    "metadata": {
      "prism_cause": "tool_continuation",
      "prism_parent_response_id": "resp_0aae3adb2ac71e2c"
    }
  }
}
```

Set `prism_parent_response_id` to the `response.id` of the reply that made the calls. Send it after that reply's `response.done` and a `conversation.item.created` for each result. Typed text and greetings have their own causes, as [Typed turns and nudges](https://docs.rime.ai/docs/prism/typed-turns.md) shows.

Most server events keep their beta names, so your handlers keep working. Read the reply text from `response.text.delta` instead of `response.audio_transcript.delta`, and take tool arguments from `response.function_call_arguments.done`. If your client uses OpenAI's current event names, such as `response.output_audio.delta`, [map them to the beta names](https://docs.rime.ai/api-reference/prism/websocket.md#the-current-openai-interface).

## Move a LiveKit agent

Install the Rime plugin with the `realtime` extra, as the [LiveKit quickstart](https://docs.rime.ai/docs/prism/livekit.md) shows. Then change the model that you pass to `AgentSession`:

```python OpenAI theme={null}
from livekit.plugins import openai

session = AgentSession(
    llm=openai.realtime.RealtimeModel(voice="marin"),
)
```

```python Prism theme={null}
from livekit.plugins import rime

session = AgentSession(
    llm=rime.realtime.RealtimeModel(voice="aurora"),
)
```

Set `RIME_API_KEY` on your backend. Remove any `vad` or `turn_detection` settings from `AgentSession`, because Prism finds the end of each turn. Your `Agent`, its instructions, and its `@function_tool` tools stay the same.

## Move a Pipecat agent

Keep your transport and `LLMContext`. Install the pinned preview from the [Pipecat quickstart](https://docs.rime.ai/docs/prism/pipecat.md), then use `RimeRealtimeLLMService` and create its aggregator pair:

```python theme={null}
from pipecat.services.rime.realtime.llm import RimeRealtimeLLMService

llm = RimeRealtimeLLMService(
    settings=RimeRealtimeLLMService.Settings(
        system_instruction="Answer questions about the cafe briefly.",
        voice="astra",
        tools=[get_opening_hours],
    ),
)
user, assistant = llm.create_context_aggregator(context)
```

Use `user` before the Rime service and `assistant` after your output transport. Prism detects turns. The quickstart explains tool results, estimated playback positions, and [tool updates and handoffs](https://docs.rime.ai/docs/prism/pipecat.md#update-tools-and-hand-off-a-conversation).

## Switch to the Rime SDK

If your backend uses OpenAI's SDK, switch to the Rime SDK in Python, Node.js, Go, or Rust. Its conversation runner plays each reply and stops playback when the caller talks over it, so your client's playback and interruption code goes away:

```python theme={null}
async with client.realtime.connect(voice=voice, instructions=instructions) as session:
    await run_conversation(session, source=browser, playback=browser, on_event=show)
```

The [SDK quickstart](https://docs.rime.ai/docs/prism/quickstart.md) runs a complete agent.

## Check that it works

Make one call. You should see `session.updated`, then `input_audio_buffer.speech_started` and `speech_stopped` while you talk, and then Prism's reply, ending with a `response.done` whose `status` is `completed`. If an `error` arrives, its code says what to fix, as [Errors and limits](https://docs.rime.ai/docs/prism/errors.md) explains.

## What you can add next

Once your agent runs on Prism, you can:

* [Adapt your instructions](https://docs.rime.ai/docs/prism/prompting.md) with Prism's rules for speech, and test them on your calls.
* [Set what Prism says while each tool runs](https://docs.rime.ai/docs/prism/tools.md#set-the-phrase-for-a-tool), or choose silence.
* [Lower the volume as soon as the caller may be speaking](https://docs.rime.ai/docs/prism/live-conversations.md#lower-playback-on-the-early-speech-hint).
* [Send the caller's words as text, or have Prism speak first](https://docs.rime.ai/docs/prism/typed-turns.md).
* [Label every reply with your own IDs](https://docs.rime.ai/docs/prism/sessions.md#label-replies-for-your-logs).


This documentation is built and hosted on [Mintlify](https://mintlify.com), a developer documentation platform.