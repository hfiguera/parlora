# Sagents backend

`Parlora.Backends.Sagents` runs Sagents tool execution for each request. Add the
optional dependency `{:sagents, "~> 0.19.2"}` only when selecting this backend.
No Sagents supervisor or persistent agent session is required.

## Configuration

```elixir
backend: {Parlora.Backends.Sagents,
  agent: &MyApp.build_task_agent/1,
  completion_tool: "finish",
  max_runs: 6,
  result: &MyApp.map_native_tool_result/1}
```

Your agent factory receives a `Parlora.BackendRequest` and returns
`{:ok, agent, state}`. It runs in the request worker, outside session and audio
callbacks. Your application supplies the model, credentials, and tools allowed for the task.

Build the agent with `replace_default_middleware: true`, empty middleware, no
fallback models, and synchronous tools. Custom execution modes, filesystem tools,
subagents, and asynchronous tools are unsupported by this adapter. Keep the
admitted tool set specific to the authorized request.

## Completion and limits

Only success from the named completion tool completes work. The result mapper
receives its native `LangChain.Message.ToolResult`; map `processed_content` to:

```elixir
%{status: :completed, facts: verified_facts, summary: "A short spoken summary"}
```

`:failed` is also supported. Use actual operation results for facts, not model
prose. Final results are limited to 64 KiB. Parlora attaches request/task/revision
and provider identities itself.

`max_runs:` defaults to 8 and accepts 1–100. Session limits bound the number of
concurrent jobs and the duration of each job. Tools and HTTP clients should also
have their own timeouts. Corrections supersede task revisions; updates to a
running request, progress, and backend clarification are unsupported.

## Cancellation and failures

Cancellation is advisory: it stops local execution and reports an uncertain
external outcome. Exceptions, deadlines, missing structured completion, and
framework failures also require reconciliation. They do not prove that an
external write failed or was undone. No operation is automatically replayed.
`:finish` close allows work to drain within the shutdown deadline; `:cancel`
stops local workers.

## OrderDesk selection

Before fetching the example dependencies, set `PARLORA_BACKEND=sagents`. Supply
`SAGENTS_API_KEY` and keep the selection when launching:

```sh
PARLORA_BACKEND=sagents mix deps.get --check-locked
PARLORA_BACKEND=sagents scripts/browser.sh
```

The example defaults to `SAGENTS_MODEL=gpt-6-luna` with reasoning `none`. This
backend text model is independent of `PARLORA_PROVIDER`. Its tools bind to the
admitted order/operation; delivery changes create drafts, and only browser
confirmation persists them. See [OrderDesk](../examples/order_desk/README.md).
