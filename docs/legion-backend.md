# Legion backend

`Parlora.Backends.Legion` runs isolated Lua agents with operations
admitted by your application. Add `{:legion, "~> 0.6.0"}` only when selecting this optional backend.
No Legion store, database, recovery worker, or framework supervisor is required.

## Configuration

Load provider credentials into the host's runtime ReqLLM configuration. For OpenAI:

```elixir
# In the host application's config/runtime.exs:
import Config
config :req_llm, :openai_api_key, System.fetch_env!("LEGION_API_KEY")
```

Select the backend when starting a session:

```elixir
backend: {Parlora.Backends.Legion,
  execution: &MyApp.build_execution/1,
  max_iterations: 6,
  max_retries: 1,
  max_tool_calls: 16,
  sandbox_timeout: 5_000,
  sandbox_max_heap: 32_000_000,
  sandbox_max_reductions: 2_000_000}
```

The execution factory receives a `Parlora.BackendRequest` and returns a map:

```elixir
%{
  model: {:openai, "gpt-6-luna", reasoning_effort: "none"},
  task: "Read the admitted order and report its status.",
  operations: %{"lookup" => fn -> MyApp.lookup_admitted_order(request.input) end},
  result: &MyApp.map_native_results/1
}
```

`request` is the factory's argument; the application functions above must be
defined by the host. Model tuple defaults carry generation options; ReqLLM provider
credentials are configured separately, not through `api_key` in that tuple.

## Operations and completion

Each operation is a function that takes no arguments and returns `{:ok, json_serializable_value}`.
Bind the admitted actor, order, and operation in those closures. Generated Lua can
call only the supplied operations through `Tool.run(name)`. Repeated calls reuse
their native result. Every admitted operation must succeed before `Tool.complete()`.

The result mapper turns native results into
`%{status: :completed | :failed, facts: map, summary: string | nil}`. An optional
`verify: fn native_results, lua_value -> boolean end` checks a derived completion
value. Model claims cannot replace required operation results. Parlora attaches
request, task, revision, and provider identities.

Native values and final results are each limited to 64 KiB. At most 16 operations
are admitted; task text is limited to 8 KiB. Tool invocations, iterations,
sandbox execution, and the whole job have finite bounds. Sandbox heap/reduction
checks are sampled and can overshoot between checks. Trusted host operations run
under the deadline for the entire job, outside the Lua heap budget.

## Lifecycle and privacy

Each request has its own agent and result collector. Conversations, persistence,
recovery, subagents, and shared execution state are unsupported. Cancellation
stops local execution and leaves external outcomes uncertain; it does not undo
side effects. Updates, progress, and backend clarification are unsupported.
Corrected requests use session revision filtering. No work is automatically replayed.

Keep upstream model/framework logging and telemetry private: they can contain
prompts, task text, or HTTP errors outside Parlora's sanitized event contract.

## OrderDesk selection

Supply `LEGION_API_KEY` and keep the backend selection during dependency fetch and
launch:

```sh
PARLORA_BACKEND=legion mix deps.get --check-locked
PARLORA_BACKEND=legion scripts/browser.sh
```

The example defaults to `LEGION_MODEL=gpt-6-luna` with reasoning `none`. Voice
provider selection is independent. See [OrderDesk](../examples/order_desk/README.md).
