> ## Documentation Index
> Fetch the complete documentation index at: https://docs.rime.ai/llms.txt
> Use this file to discover all available pages before exploring further.

# Handle slow tools and long tasks

> Speak to the caller while a slow Prism tool runs, and hand long tasks to your own agent, in Python or Node.js. The guide also covers tool timeouts and results that arrive late.

When a lookup takes more than a few seconds, the caller hears silence after the tool's phrase. Your backend can fill that wait with short lines, or hand a task with many steps to your own agent. A result can also arrive after its tool round has closed, and your backend then reports the result with a nudge. The snippets extend the loop in [Run each call and continue the reply](https://docs.rime.ai/docs/prism/tools.md#run-each-call-and-continue-the-reply), with its imports and its `run_tools`, `run_tool`, and `finish_round` functions (`runTools`, `runTool`, and `finishRound` in Node.js).

## Speak while a slow tool runs

A few seconds of silence on a phone call feels like a dropped line. When a lookup runs longer than that, ask for nudges that say a short line, and report the result with one more nudge:

1. Start the lookup. If the result comes back within a few seconds, submit it, and `finish_round` continues the reply as usual.
2. Otherwise, ask for a nudge that tells the caller that you are still working on it. Repeat it about every 10 seconds, at most two or three times, because the lines start to sound alike.
3. When the result arrives, submit it, and ask for a nudge that reports it, as in [Report a result later](#report-a-result-later).

The first nudge closes the round, as the caller's speech does. After it, `continue_reply` (`continueReply`) raises `RimeInputError`, which `finish_round` catches, so always report the result with a nudge. Prism also sends no `tool_result_timeout` for that round, so set your own deadline from the start of the lookup. When the lookup takes too long, submit an error result and report it.

`run_slow_tool` (`runSlowTool` in Node.js) says a line after 4 seconds and another 10 seconds after the first line starts. It submits an error result 30 seconds after the lookup starts. The lines run on their own task, so a slow line cannot delay that deadline, and the lines stop if Prism refuses one. Start it in `run_tools` in place of `run_tool`. `lookup` is your own async function, which takes the arguments of the call and returns the result. At the deadline, `run_slow_tool` cancels the lookup, and `runSlowTool` aborts the `AbortSignal` that it passes to `lookup` as a second argument.

> [tab] Python
>
> ```python theme={null}
> from rimelabs_sdk.realtime import RealtimeAdmissionTimeout, RimeRealtimeError
>
> STILL_WORKING = "Tell the caller in one short sentence that you are still working on it."
>
>
> async def say_still_working(session, nudged):
>     for wait in (4, 10):  # A line after 4 s, and another 10 s after the first starts
>         await asyncio.sleep(wait)
>         nudged.set()  # A nudge closes the round.
>         try:
>             await session.request_reply(instruction=STILL_WORKING)
>         except (RimeRealtimeError, RealtimeAdmissionTimeout):
>             return  # The caller spoke first, or the wait ran out, so stop the lines.
>
>
> async def run_slow_tool(session, call, lookup):
>     task = asyncio.create_task(lookup(call.arguments))  # Your own lookup
>     nudged = asyncio.Event()
>     lines = asyncio.create_task(say_still_working(session, nudged))
>     await asyncio.wait({task}, timeout=30)  # 30 s from the start of the lookup
>     lines.cancel()
>     if not task.done():
>         task.cancel()
>         result = {"error": "The lookup timed out"}
>     elif task.exception():
>         result = {"error": f"{call.name} failed"}
>     else:
>         result = task.result()
>     await session.submit_tool_result(call.call, json.dumps(result))
>     if nudged.is_set():
>         await session.request_reply(tool_call=call.call)  # Prism tells the caller the result.
> ```

> [tab] Node.js
>
> ```javascript theme={null}
> import { setTimeout as sleep } from "node:timers/promises";
>
> const STILL_WORKING = "Tell the caller in one short sentence that you are still working on it.";
>
> async function sayStillWorking(session, state, signal) {
>   for (const wait of [4000, 10000]) { // A line after 4 s, and another 10 s after the first starts
>     await sleep(wait, undefined, { signal });
>     state.nudged = true; // A nudge closes the round.
>     await session.requestReply({ instruction: STILL_WORKING, signal });
>   }
> }
>
> async function runSlowTool(session, call, lookup) {
>   const stop = new AbortController(); // Stops the lookup, the 30 s timer, and the lines.
>   const lookupDone = lookup(call.arguments, stop.signal) // Your own lookup
>     .catch(() => ({ error: `${call.name} failed` }));
>   // 30 s from the start of the lookup
>   const timedOut = sleep(30000, { error: "The lookup timed out" }, { signal: stop.signal });
>   const state = { nudged: false };
>   sayStillWorking(session, state, stop.signal).catch(() => {}); // Stopping the lines rejects them.
>   const result = await Promise.race([lookupDone, timedOut]);
>   stop.abort();
>   await session.submitToolResult(call.call, JSON.stringify(result));
>   if (state.nudged) {
>     await session.requestReply({ toolCall: call.call }); // Prism tells the caller the result.
>   }
> }
> ```

With a 20-second lookup, for example, Prism says a line such as "I am still working on it." at 4 and 14 seconds, and then gives the hours. With a 40-second lookup, the error result goes in at 30 seconds, and Prism says that the lookup timed out. If a line is still playing when the result arrives, the report starts after the line ends.

## Delegate long tasks to your agent

A single tool with a clear description works in one call, such as a lookup or a booking. A reply can make several calls, and a continuation can make more, so short chains work too. For work with many steps or long reasoning, give Prism one tool, such as `delegate`, that hands the task to your agent. Its description says what your agent can do, and its one argument is the task:

> [tab] Python
>
> ```python theme={null}
> from rimelabs_sdk.realtime import PrismFiller, ToolDefinition
>
> DELEGATE = ToolDefinition(
>     name="delegate",
>     description=(
>         "Hand a task to the Juniper Cafe booking agent, which can find, change, "
>         "and cancel table bookings and text the caller a confirmation."
>     ),
>     parameters={
>         "type": "object",
>         "properties": {"task": {"type": "string", "description": "The caller's request, in full"}},
>         "required": ["task"],
>     },
>     prism_filler=PrismFiller(type="text", text="Sure, I will take care of that."),
> )
> ```

> [tab] Node.js
>
> ```javascript theme={null}
> const delegateTool = {
>   name: "delegate",
>   description:
>     "Hand a task to the Juniper Cafe booking agent, which can find, change, " +
>     "and cancel table bookings and text the caller a confirmation.",
>   parameters: {
>     type: "object",
>     properties: { task: { type: "string", description: "The caller's request, in full" } },
>     required: ["task"],
>   },
>   prismFiller: { type: "text", text: "Sure, I will take care of that." },
> };
> ```

Add a rule to the instructions, such as "Call delegate for any request that needs more than one step, such as changing a booking." Run each `delegate` call with `run_slow_tool` (`runSlowTool` in Node.js), and pass your agent as `lookup`. Raise its 30-second deadline to the longest time that your agent needs. Plan for five things while your agent works:

* **Lower the wait:** start your agent as soon as the `tool.call` event arrives, as `run_tools` does. The tool's [own phrase](https://docs.rime.ai/docs/prism/tools.md#set-the-phrase-for-a-tool) plays meanwhile.
* **Keep the caller company:** nudges fill the wait, as [Speak while a slow tool runs](#speak-while-a-slow-tool-runs) shows. A last nudge [reports the outcome](#report-a-result-later).
* **Keep task state in your code:** your agent and your database hold each task, its progress, and its outcome. Prism's history is a conversation, not a task log.
* **Handle a change of plan:** the caller may change the request while your agent works. Prism may then make a new `delegate` call, or only reply, for example to confirm the details. Prism leaves the running task to your code, so cancel or redirect it there. Report only an outcome that matches the latest request.
* **Check the outcome in code:** treat the `tool.call` event and your agent's result as the record of each action. Confirm outcomes from your agent, not from the reply text.

## Handle edge cases

### Timeouts and late results

Prism waits for every result of a round, and then for the continuation. Each session publishes both waits in `session.info`, so read them there instead of hard-coding them. This line prints `90.0 60.0` in Python and `90 60` in Node.js:

> [tab] Python
>
> ```python theme={null}
> print(session.info.tool_result_timeout_s, session.info.tool_continuation_timeout_s)
> ```

> [tab] Node.js
>
> ```javascript theme={null}
> console.log(session.info.toolResultTimeoutS, session.info.toolContinuationTimeoutS);
> ```

| Wait | Python, Node.js | Value | Starts | When it runs out |
| - | - | - | - | - |
| Results | `tool_result_timeout_s`, `toolResultTimeoutS` | 90 seconds | When the reply that made the calls ends | Prism sends an `error` with code `tool_result_timeout`, records each call without a result as an unknown outcome, and closes the round. |
| Continuation | `tool_continuation_timeout_s`, `toolContinuationTimeoutS` | 60 seconds | When every call has a result and the reply that made them has ended | The round closes, with no error. |

`None` (`null` in Node.js) means that Prism did not publish the wait. The SDK cannot tell a missing value from no deadline.

Prism still records a late result, but the result does not start a reply, and `continue_reply` raises `RimeRealtimeError` with code `tool_continuation_unavailable`.

### Report a result later

A round can end before it uses a result, because the result comes too late or the caller speaks first. Prism keeps that result in the conversation history, but it mentions the result only if the caller asks. To tell the caller, submit the result, and ask for a nudge that reports it. Like any nudge, it waits until Prism is idle. In this code, `call` is the `tool.call` event, and `result` is the return value of your lookup:

> [tab] Python
>
> ```python theme={null}
> await session.submit_tool_result(call.call, json.dumps(result))
> await session.request_reply(tool_call=call.call)  # Prism tells the caller the result.
> ```

> [tab] Node.js
>
> ```javascript theme={null}
> await session.submitToolResult(call.call, JSON.stringify(result));
> await session.requestReply({ toolCall: call.call }); // Prism tells the caller the result.
> ```

Two cases show how this works:

| Case | What happens |
| - | - |
| The lookup takes 95 seconds. | Prism sends `tool_result_timeout` at 90 seconds, records the late result, and refuses the continuation. A nudge then gets the reply, "We close at 2 p.m. on Saturdays." |
| The caller speaks while the lookup runs. | Prism replies to the caller, and that reply may call the tool again. When the result is in, `continue_reply` raises `RimeInputError`, and a nudge reports the hours. |

## Next

> [card] [Errors and limits](https://docs.rime.ai/docs/prism/errors.md#tool-calls)
>
> Look up each error code of a tool round, such as `tool_result_timeout`, and what to do about it.


This documentation is built and hosted on [Mintlify](https://mintlify.com), a developer documentation platform.