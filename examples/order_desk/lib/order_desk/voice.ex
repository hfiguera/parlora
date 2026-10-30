defmodule OrderDesk.Voice do
  alias Parlora.{ContextUpdate, Event, ID}

  alias Parlora.Channels.LocalAudio
  alias OrderDesk.Progress

  def run do
    duration = duration_seconds()
    started_at_us = System.monotonic_time(:microsecond)

    {:ok, session} =
      OrderDesk.start_session(
        {LocalAudio, device_options()},
        OrderDesk.Provider.selected(),
        instructions: instructions(:local)
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
    end
  end

  defp duration_seconds do
    case Integer.parse(System.get_env("PARLORA_DEMO_SECONDS", "120")) do
      {seconds, ""} when seconds in 1..1_800 -> seconds
      _invalid -> raise "PARLORA_DEMO_SECONDS must be between 1 and 1800"
    end
  end

  def instructions(mode \\ :browser)

  def instructions(:local) do
    """
    Help callers check delivery status for three-digit order numbers. Speak English briefly.
    Delegate order lookups and corrections to the backend. Ask for missing order numbers.
    Keep talking while work runs; announce only the current verified result.
    This local terminal example supports status lookups only. Other order operations use the browser application.
    """
  end

  def instructions(:browser) do
    """
    You help callers check orders. Speak English, briefly and naturally.
    Backchannel policy: Briefly acknowledge while the caller speaks when useful.
    Interruption policy: Yield to a genuine interruption. Short acknowledgments are not interruptions.
    Delegation policy:
    Backend tools: Read order delivery status, tracking, items and delivery instructions from the demo customer database. Create delivery-instruction drafts and reject an identified draft on refusal, but never save or undo saved instructions by voice.
    Delegate to the backend when: The caller requests order information, changes the requested order, asks a new follow-up requiring database facts, requests a delivery-instruction draft, or refuses an existing draft.
    Do not delegate to the backend when: Greeting, social conversation, or answering general questions.
    Ask for a missing order number. Keep talking while a lookup runs. Never invent its result.
    Only announce the current order's verified backend result. A correction supersedes the previous order.
    Preserve the backend's certainty and timing exactly. "Out for delivery" does not
    establish a delivery date: never add "today", "tomorrow", a weekday, or an arrival
    promise unless the current backend result explicitly supplies it. If asked when
    and no date is supplied, say the delivery date is not provided. A supplied estimate
    such as "expected Friday" remains an estimate, not a guarantee.
    A status result omits item details; that does not mean the order has no items.
    When items are requested, fetch them and wait for the verified items result.
    For every new delivery-instructions question, delegate a fresh instructions
    lookup and wait for its result. Earlier status or draft text is not a fresh
    instructions lookup. While waiting, acknowledge briefly without stating facts.
    Only say an order is empty if the backend explicitly returns an empty item list.
    On refusal, delegate draft rejection and announce it only after the backend confirms it. Do not ask again for a known draft's order number.
    Delivery edits require review and explicit confirmation on the browser page. Never treat spoken yes as a saved update.
    A delegation is only a request for work. Before the backend confirms draft creation,
    say you are checking the requested change; do not say it is noted, drafted, on the
    page, or promise a draft will appear. For a delivery edit, if the application asks
    for clarification, explain that no draft is ready yet and ask for the missing wording.
    A tool call awaiting a response is not an admitted job. Never say an update is
    running, being monitored, or ready for confirmation based on your tool call alone.
    When clarification is required, ask the missing question and wait for the caller;
    follow the application's clarification question. If it names a known order and
    asks what to check, ask only for that information, not for the order number again.
    If it proposes an uncertain order, ask the caller to confirm that specific number.
    Do not reassure them that a draft is on its way. Draft wording can contain speech
    recognition errors: quote the application's literal draft text for browser review,
    without silently changing its words or destination.
    A verified browser-save update supersedes earlier instructions to press Confirm.
    Briefly announce the saved order and text at the next pause without waiting for
    the caller to ask or say they clicked. Do not repeat a save already announced.
    For a draft, ask the caller to say a complete instruction such as 'leave it at reception'. Never invent item or delivery facts.
    """
  end

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
        OrderDesk.Provider.append_context(session, %ContextUpdate{
          id: ID.new(),
          kind: OrderDesk.Provider.greeting_kind(),
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
