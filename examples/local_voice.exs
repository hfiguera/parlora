Code.require_file("support/order_policy.ex", __DIR__)
Code.require_file("support/order_agent.ex", __DIR__)
Code.require_file("support/progress.ex", __DIR__)

defmodule Parlora.Examples.LocalVoice do
  alias Parlora.{ContextUpdate, Event, ID}

  alias Parlora.Backends.Jido, as: Backend
  alias Parlora.Channels.LocalAudio
  alias Parlora.Examples.{OrderAgent, OrderPolicy, Progress}
  alias Parlora.Providers.{Gemini, Grok}

  def run do
    duration = duration_seconds()
    provider = Application.fetch_env!(:parlora, :example_provider)
    settings = [api_key: Application.fetch_env!(:parlora, :example_api_key)]

    settings =
      if provider == Grok,
        do:
          Keyword.put(
            settings,
            :reasoning_effort,
            Application.fetch_env!(:parlora, :example_reasoning_effort)
          ),
        else: settings

    started_at_us = System.monotonic_time(:microsecond)
    {:ok, jido} = Jido.start_link(name: Parlora.Examples.Jido)

    {:ok, session} =
      Parlora.start_session(
        channel: {LocalAudio, device_options()},
        limits:
          if(provider in [Gemini, Grok],
            do: provider.audio_limits(),
            else: []
          ),
        provider: {provider, settings},
        backend:
          {Backend,
           agent: OrderAgent, agent_options: [jido: Parlora.Examples.Jido], result: &map_result/1},
        context_policy: {OrderPolicy, []},
        instructions: instructions(),
        event_sink: self()
      )

    parent = self()
    reader = spawn(fn -> read_commands(parent) end)
    Process.send_after(self(), :quit, duration * 1_000)

    IO.puts(
      "Wait for the greeting, then say: Check order 123. While the lookup runs, say: Actually, order 124."
    )

    IO.puts(
      "Type /mark, /status, /quit, /mute, /unmute, /stop, or /resume. This demo ends after #{duration} seconds."
    )

    IO.puts("Audio notices include normal startup/pauses; use /mark when you hear a gap.")

    try do
      loop(session, started_at_us)
    after
      Process.exit(reader, :kill)
      Supervisor.stop(jido)
    end
  end

  defp duration_seconds do
    case Integer.parse(System.get_env("PARLORA_DEMO_SECONDS", "120")) do
      {seconds, ""} when seconds in 1..1_800 -> seconds
      _invalid -> raise "PARLORA_DEMO_SECONDS must be between 1 and 1800"
    end
  end

  defp instructions do
    """
    You help callers check orders. Speak English, briefly and naturally.
    Backchannel policy: Briefly acknowledge while the caller speaks when useful.
    Interruption policy: Yield to a genuine interruption. Short acknowledgments are not interruptions.
    Delegation policy:
    Backend tools: Read-only delivery lookup for a three-digit order number.
    Delegate to the backend when: The caller requests an order lookup or corrects its order number.
    Do not delegate to the backend when: Greeting, social conversation, or answering general questions.
    Ask for a missing order number. Keep talking while a lookup runs. Never invent its result.
    Only announce the current order's verified backend result. A correction supersedes the previous order.
    """
  end

  defp map_result(%{status: status, result: result}),
    do: %{status: status, facts: Map.take(result, [:order]), summary: result.summary}

  defp device_options do
    host =
      System.get_env(
        "CPAL_HOST",
        if(:os.type() == {:unix, :darwin}, do: "CoreAudio", else: "PulseAudio")
      )

    {:ok, devices} = LocalAudio.devices(host)
    [host: host] |> select_device(devices, :input) |> select_device(devices, :output)
  end

  defp select_device(options, devices, direction) do
    env = if direction == :input, do: "CPAL_INPUT", else: "CPAL_OUTPUT"
    key = if direction == :input, do: :input_device, else: :output_device

    case System.get_env(env) do
      nil ->
        options

      name ->
        device =
          Enum.find(devices, &(&1.name == name and Map.fetch!(&1, direction) != nil)) ||
            raise "Device not found"

        Keyword.put(options, key, device.id)
    end
  end

  defp read_commands(parent) do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        send(parent, {:command, String.trim(line)})
        read_commands(parent)
    end
  end

  defp loop(session, started_at_us) do
    receive do
      :quit ->
        close(session, started_at_us)

      {:command, "/quit"} ->
        close(session, started_at_us)

      {:command, "/mark"} ->
        IO.puts("[#{Progress.mark(started_at_us)}]")
        loop(session, started_at_us)

      {:command, command} ->
        control(session, command)
        loop(session, started_at_us)

      {:parlora_event, %Event{source: :session, type: :ready}} ->
        Parlora.append_context(session, %ContextUpdate{
          id: ID.new(),
          kind:
            if(provider in [Gemini, Grok],
              do: :speakable,
              else: :instruction
            ),
          provider_generation: 0,
          content: "Speak first in English. Briefly greet the caller and offer to check an order."
        })

        loop(session, started_at_us)

      {:parlora_event, %Event{type: :transcript_delta, payload: payload}} ->
        IO.write("#{payload.speaker}: #{payload.delta}\n")
        loop(session, started_at_us)

      {:parlora_event, %Event{source: :session, type: :closed, payload: payload}} ->
        IO.puts(
          "Session closed: finalized=#{payload.finalized?}, usage=#{inspect(payload.usage)}"
        )

      {:parlora_event, %Event{} = event} ->
        print_event(event, started_at_us)

        loop(session, started_at_us)
    end
  end

  defp control(session, "/mute"), do: Parlora.control(session, {:input_muted, true})

  defp control(session, "/status"),
    do: session |> Parlora.status() |> Progress.status() |> IO.puts()

  defp control(session, "/unmute"), do: Parlora.control(session, {:input_muted, false})

  defp control(session, "/stop") do
    Parlora.control(session, {:suppress_output, true})
    Parlora.control(session, {:clear_output, :next})
  end

  defp control(session, "/resume"), do: Parlora.control(session, {:suppress_output, false})
  defp control(_session, _command), do: IO.puts("Unknown command")

  defp close(session, started_at_us) do
    Parlora.close(session, :finish)

    await_closed(started_at_us, System.monotonic_time(:millisecond) + 6_000)
  end

  defp await_closed(started_at_us, deadline) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: IO.puts("Session close deadline elapsed"),
      else: receive_closed(started_at_us, deadline)
  end

  defp receive_closed(started_at_us, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:parlora_event, %Event{source: :session, type: :closed, payload: payload}} ->
        IO.puts(
          "Session closed: finalized=#{payload.finalized?}, usage=#{inspect(payload.usage)}"
        )

      {:parlora_event, %Event{} = event} ->
        print_event(event, started_at_us)
        await_closed(started_at_us, deadline)
    after
      remaining -> IO.puts("Session close deadline elapsed")
    end
  end

  defp print_event(event, started_at_us) do
    case Progress.audio(event, started_at_us) || Progress.event(event) do
      nil -> :ok
      message -> IO.puts("[#{message}]")
    end
  end
end

Parlora.Examples.LocalVoice.run()
