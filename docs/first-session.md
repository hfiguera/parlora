# Your first working session

This tutorial creates a complete local voice application. Its only business
operation is a read-only lookup of a demo shop's opening hours. You need a working
microphone/speakers and an OpenAI key with access to `gpt-live-1`. No TypeSafe key,
backend language model, database, or custom application modules are needed.

## 1. Create the host application

Create a fresh Mix application:

```sh
mix new voice_demo
cd voice_demo
mkdir -p config
```

In the new application's `mix.exs`, replace `deps/0` with:

```elixir
defp deps do
  [
    {:parlora, "~> 0.2.0"},
    {:jido, "== 2.4.0"}
  ]
end
```

Use a compatible Elixir/OTP pair from the [requirements guide](beam-compatibility.md).
This new host uses the runtime you select for it.

## 2. Configure the build before compiling

Install the [native prerequisites for local audio only](beam-compatibility.md#choose-native-bindings-before-compiling).
Create `config/config.exs` in **voice_demo**:

```elixir
import Config

# This application uses local audio only: do not build the browser Opus binding.
config :parlora, native_audio: true, native_opus: false

if :os.type() == {:unix, :darwin} do
  config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
end
```

Then fetch dependencies:

```sh
mix deps.get
```

## 3. Add the complete application code

Save the following as `first_voice.exs` in the `voice_demo` directory. It defines
all modules used below; keep the generated `lib/voice_demo.ex` unchanged.

<!-- first_voice.exs -->
```elixir
defmodule FirstVoice.LookupHours do
  use Jido.Action,
    name: "lookup_hours",
    schema: [
      input: [type: :map, required: true],
      request_id: [type: :string],
      task_id: [type: :string],
      task_revision: [type: :integer]
    ]

  @impl true
  def run(%{input: %{operation: :opening_hours}}, _context) do
    {:ok,
     %{
       status: :completed,
       last_answer: %{shop: "Demo shop", hours: "Monday to Friday, 09:00 to 17:00"}
     }}
  end
end

defmodule FirstVoice.Agent do
  use Jido.Agent,
    name: "opening_hours",
    schema: [status: [type: :atom, default: :idle], last_answer: [type: :map, default: %{}]],
    signal_routes: [{"parlora.request", FirstVoice.LookupHours}]
end

defmodule FirstVoice.Policy do
  @behaviour Parlora.ContextPolicy

  @impl true
  def interpret(snapshot, _trigger, _options) do
    decisions =
      for {id, %{status: :pending}} <- snapshot.pending_delegations do
        %Parlora.ContextDecision{
          kind: :start_task,
          delegation_id: id,
          input: %{operation: :opening_hours}
        }
      end

    {:ok, decisions}
  end
end

defmodule FirstVoice do
  def run(options \\ []) do
    provider =
      Keyword.get_lazy(options, :provider, fn ->
        {Parlora.Providers.OpenAI, api_key: System.fetch_env!("OPENAI_API_KEY")}
      end)

    {:ok, supervisor} =
      Supervisor.start_link([{Jido, name: FirstVoice.Jido}], strategy: :one_for_one)

    try do
      {:ok, session} =
        Parlora.start_session(
          channel: Keyword.get(options, :channel, {Parlora.Channels.LocalAudio, []}),
          provider: provider,
          backend:
            {Parlora.Backends.Jido,
             agent: FirstVoice.Agent,
             agent_options: [jido: FirstVoice.Jido],
             result: &map_result/1},
          context_policy: {FirstVoice.Policy, []},
          instructions: """
          Help callers ask about the demo shop's opening hours. Delegate opening-hours
          questions to the backend and answer only from its verified result.
          Other business operations are unavailable. Keep spoken answers brief.
          """,
          event_sink: self()
        )

      ref = Process.monitor(session)
      timer = Process.send_after(self(), {:stop_demo, session}, 120_000)

      try do
        receive_events(session, ref)
      after
        Process.cancel_timer(timer)
        if Process.alive?(session), do: Parlora.close(session, :cancel)
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  def map_result(%{status: status, result: facts}) do
    %{status: status, facts: facts, summary: "#{facts.shop} is open #{facts.hours}."}
  end

  defp receive_events(session, ref) do
    receive do
      {:parlora_event, %Parlora.Event{source: :session, type: :ready}} ->
        IO.puts("Ready. Ask: What are the shop's opening hours?")
        receive_events(session, ref)

      {:parlora_event, %Parlora.Event{type: :failed}} ->
        IO.puts("A voice adapter failed; closing the session.")
        Parlora.close(session, :cancel)
        receive_events(session, ref)

      {:parlora_event, %Parlora.Event{source: :session, type: :closed}} ->
        IO.puts("Session closed; waiting for cleanup.")
        receive_events(session, ref)

      {:DOWN, ^ref, :process, ^session, reason} ->
        IO.puts("Session process stopped.")
        if reason == :normal, do: :ok, else: {:error, :session_stopped}

      {:stop_demo, ^session} ->
        Parlora.close(session, :cancel)
        receive_events(session, ref)

      _event ->
        receive_events(session, ref)
    end
  end
end
```

The policy has exactly one allowed operation. Every pending delegation maps to
that same lookup of opening hours; claimed or cancelled delegations do not start work
again. This demo handles just this one operation; it does not interpret general requests.
For orders, corrections, or multiple operations, implement a policy that checks
caller context, task revisions, and permissions; see the [policy contract](public-interfaces.md#7-parlora-contextpolicy)
and [OrderDesk workflows](../examples/order_desk/APPLICATION.md).

The Jido instance belongs to the demo supervisor. The calling process stays alive
as the event receiver, waits for readiness, closes after two minutes, waits for
the session process to exit, and stops its Jido supervisor. `map_result/1` maps
Jido completion data into verified Parlora facts and a spoken summary.

## 4. Start talking

Supply `OPENAI_API_KEY` in this shell using your secret management, then run:

```sh
mix run -r first_voice.exs -e 'FirstVoice.run()'
```

Allow microphone access if prompted. When the terminal prints **Ready**, ask
“What are the shop's opening hours?” You should hear that the demo shop is open
Monday to Friday, 09:00 to 17:00. There is no automatic greeting; speak after
Ready. The session closes automatically after two minutes. Interrupt the Mix
process to exit sooner; normal application shutdown releases its supervised sessions.

Use headphones to reduce feedback. LocalAudio uses your default input/output
devices. For device selection, call `Parlora.Channels.LocalAudio.devices/0`, then
pass the returned device IDs in a channel tuple:

```elixir
FirstVoice.run(channel: {Parlora.Channels.LocalAudio,
  input_device: input_id,
  output_device: output_id})
```

`input_id` and `output_id` must come from device discovery; the normal command
uses defaults and requires no IDs. To change provider, supply a `provider:` tuple
as described in the [provider guides](openai-provider.md).

## If startup fails

- A missing `OPENAI_API_KEY` fails before opening a session. Set the key in the
  same shell that runs Mix; this script reads it at runtime.
- If native compilation fails, check the [platform prerequisites](beam-compatibility.md)
  and confirm `native_opus: false` is in the **host** configuration read at compile time.
- If microphone access or device opening fails, check OS permissions and device
  discovery. Local audio on Linux needs a service compatible with PulseAudio.
- If the provider rejects startup, check model access and the credential. The
  example handles failure/closure; do not treat a returned session PID as Ready.

Once this works, use [Getting started](using-parlora.md) for session controls,
application context, browser/phone channels, and session ownership in applications that stay running.
