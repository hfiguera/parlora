> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# How Tools Execute

> A visual guide to how a tool call is sequenced against the agent's speech, using a shared timeline: what the baseline looks like, and how each configuration flag changes it.

Every tool call plays out on a timeline with three phases: what the **assistant** says before the call, when the **tool** actually runs, and what the assistant says after. The configuration flags each change the *timing* of these phases: whether a phase exists, when it starts, whether it overlaps the others, and whether the caller can interrupt. Every diagram opens the same way, with the caller asking for something.

The first choice is the execution mode. Every other flag notes in its heading which modes it applies to, and each compares against the **baseline** (sync, all flags off). That baseline is a comparison point, not the shipped configuration: `require_speech_before_tool_call` is on by default.

Caller speech

Assistant speech

Tool executing

Blocked / dropped

# `execution_mode`: sync vs async

The first and biggest choice. **Sync** (the default, and the baseline for the rest of this page): the assistant goes silent and the answer waits until the tool returns. **Async**: the assistant fires the tool and forgets it, the conversation keeps going in parallel. The key subtlety with async: the result is detached from tool timing. A reply before the tool finishes can't use it, and the result then sits in context until a later turn actually needs it, whenever that happens.

SYNC (default / baseline)

asks something

optional line

silent (waiting)

answers

executing

ASYNC

# `require_speech_before_tool_call` (sync and async)

Off, the pre-tool line is optional: the model decides whether to say anything first. On — the default — the assistant is forced to speak first, so the pre-tool line always appears and the tool never runs in silence.

OFF

asks something

optional line

answers

executing

ON (default)

asks something

required line

answers

executing

# `wait_for_speech_before_tool_call` (sync and async)

To cut latency, Phonic normally dispatches the tool as soon as the model emits the call, which can overlap the assistant's own speech. Turn this on to hold the tool until the assistant has finished speaking.

asks something

speaking...

answers

executing

asks something

speaking...

answers

executing

# `forbid_tool_call_after_speech` (sync and async)

Off (the baseline), the assistant can call a tool even after it has already spoken in the turn. On, if the assistant already spoke this turn, the tool call is dropped rather than executed, useful for tools that only make sense as the very first thing the agent does.

asks something

speaks this turn

executes anyway

asks something

speaks this turn

call dropped

# `uninterruptible` (sync only)

Off (the baseline), caller speech during a sync tool call cancels the call and the assistant handles the new input. On, the caller can't interrupt the tool, but the assistant still hears them and can respond to it once the tool completes.

asks something

barges in

says a line

handles new input

executing

cancelled

asks something

talks

talks

says a line

answers (heard them)

executing (locked)

# `forbid_speech_after_tool_call` (sync and async)

Off (the baseline), the assistant generates a response once the result is back. On, no response is generated after the tool returns, useful when the tool's side effect is the whole point and you don't want the agent to narrate it.

asks something

says a line

answers

executing

asks something

says a line

stays silent after the tool

executing

# `wait_for_response` (async only)

Off (the baseline for async), the tool behaves like plain async: the result is added to context and used only when a later turn needs it, nothing is held. With `wait_for_response` on, the async tool enters "busy mode": the agent stops offering other tools and stays on the task, keeps the caller posted while it waits, and proactively delivers the result the moment it lands. The conversation isn't frozen: the caller and agent can still talk during the wait, the agent just can't call other tools.

OFF (default async)

asks something

checks in

line + fires tool

tool has been called

status update

delivers result

starts

...still running...

finishing

result ready →

# Common combination: long-running background task

`async` + `wait_for_response` + `forbid_speech_after_tool_call` + `allow_tool_chaining: false`. Use this when a tool kicks off slow backend work (a lookup that takes several seconds, a booking, a payment) and you want the agent to acknowledge the request, skip narrating the tool call itself, keep the caller posted while it runs, then come back with the answer on its own. (Compare the `wait_for_response` timeline above, where the agent announces "tool has been called" right after firing; `forbid_speech_after_tool_call` is what removes that.)

| Flag                            | What it contributes                                                                                                                                                                                       |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `execution_mode: async`         | the call can take as long as it needs without blocking the turn or being cancelled by caller speech                                                                                                       |
| `wait_for_response`             | the agent holds other tools and follow-ups, waits for the result, then proactively delivers it                                                                                                            |
| `forbid_speech_after_tool_call` | stops the agent from narrating or chattering right after it fires the tool                                                                                                                                |
| `allow_tool_chaining: false`    | chaining is on by default, and the API rejects `wait_for_response` together with it: `wait_for_response` already holds every other tool call until the result lands, so chaining has nothing left to fire |

asks something

checks in

line + fires tool

(no announcement)

status update

delivers result

starts

...still running...

finishing

result ready →