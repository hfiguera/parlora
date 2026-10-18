# A drain-only PCMU channel isolates spoken-notification behavior from hardware.
# It does not simulate carrier delivery or prove human hearing.
defmodule SaveAnnouncementSink do
  use GenServer
  use Parlora.AdapterClient
  @behaviour Parlora.Channel
  alias Parlora.Event
  @impl true
  def start_link(init, _options), do: GenServer.start_link(__MODULE__, init)

  @impl true
  def init(init) do
    Event.emit(init, :channel, :ready, %{
      capabilities: caps(init.audio_format),
      format: init.audio_format
    })

    {:ok, init}
  end

  @impl true
  def handle_call(:capabilities, _from, init), do: {:reply, {:ok, caps(init.audio_format)}, init}
  def handle_call({:read, _budget}, _from, init), do: {:reply, {:ok, []}, init}
  def handle_call({:write, _frame}, _from, init), do: {:reply, :ok, init}

  def handle_call({:close, id, _reason}, _from, init) do
    Event.emit(init, :channel, :closed, %{}, command_id: id)
    {:reply, :ok, init}
  end

  defp caps(format),
    do: %Parlora.Channel.Capabilities{
      input_formats: [format],
      output_formats: [format],
      full_duplex?: true
    }
end

defmodule SaveAnnouncementLiveCheck do
  alias OrderDesk.{SaveAnnouncements, Store}
  alias Parlora.{ContextUpdate, Event, ID}

  def run do
    :memory = if Application.fetch_env!(:order_desk, :database) == ":memory:", do: :memory
    actor = "announcement-validation"
    proposal = ID.new()
    {:ok, _} = Store.propose(actor, "124", "Leave it with my neighbor", proposal)

    {channel, format} =
      case System.get_env("PARLORA_SAVE_PROBE_FORMAT") do
        "pcm" -> {{Parlora.Channels.LocalAudio, device: :synthetic}, %Parlora.AudioFormat{}}
        "pcm_sink" -> {{SaveAnnouncementSink, []}, %Parlora.AudioFormat{}}
        _pcmu -> {{SaveAnnouncementSink, []}, Parlora.AudioFormat.pcmu()}
      end

    {:ok, session} =
      OrderDesk.start_session(
        channel,
        {Parlora.Providers.OpenAI, api_key: Application.fetch_env!(:order_desk, :openai_api_key)},
        audio_format: format,
        instructions: OrderDesk.Voice.instructions()
      )

    {:ok, worker} = SaveAnnouncements.start_link(session: session)
    started = System.monotonic_time(:millisecond)

    try do
      wait_ready(session, started + 10_000)

      :ok =
        Parlora.append_context(session, %ContextUpdate{
          id: ID.new(),
          kind: :speakable,
          provider_generation: 0,
          content:
            "A draft now exists for order 124: Leave it with my neighbor. Tell the caller to review the exact order and text on the page and press Confirm to save it. Nothing is saved yet."
        })

      loop(session, worker, actor, proposal, started, false, started + 40_000)
    after
      Parlora.close(session, :cancel)
    end

    receive do
      {:parlora_event, %Event{source: :session, type: :closed, payload: payload}} ->
        IO.inspect(payload, label: "closed")
    after
      8_000 -> raise "Session did not close"
    end
  end

  defp wait_ready(session, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: raise("Startup deadline")

    receive do
      {:parlora_event, %Event{source: :session, type: :ready}} -> :ok
      _event -> wait_ready(session, deadline)
    after
      100 -> wait_ready(session, deadline)
    end
  end

  defp loop(session, worker, actor, proposal, started, saved, deadline) do
    if System.monotonic_time(:millisecond) > deadline,
      do: raise("No generated save confirmation before deadline")

    status = SaveAnnouncements.status(worker)

    if get_in(status, [:evidence, "124", :stage]) == :transcript_observed do
      IO.inspect(status, label: "announcement")
    else
      saved =
        receive do
          {:parlora_event,
           %Event{type: :transcript_delta, payload: %{speaker: :assistant, delta: text}}} ->
            IO.puts(
              Jason.encode!(%{ms: System.monotonic_time(:millisecond) - started, assistant: text})
            )

            unless saved do
              {:ok, result} = Store.confirm(actor, proposal)
              SaveAnnouncements.saved(worker, result)
              IO.puts("CONFIRMED_IN_ISOLATED_DATABASE_WHILE_ASSISTANT_SPEAKING")
            end

            true

          {:parlora_event, %Event{type: :audio_discontinuity} = event} ->
            IO.puts(
              Jason.encode!(%{
                at_us: event.observed_at_us,
                ms: System.monotonic_time(:millisecond) - started,
                source: event.source,
                discontinuity: event.payload
              })
            )

            saved

          {:parlora_event, %Event{type: :failed} = event} ->
            IO.inspect(Map.take(event, [:source, :payload]), label: "failure")
            raise "Provider/session failed"

          _event ->
            saved
        after
          100 -> saved
        end

      loop(session, worker, actor, proposal, started, saved, deadline)
    end
  end
end

SaveAnnouncementLiveCheck.run()
