defmodule OrderDesk.Greeting do
  @moduledoc "Bounded browser and phone opening using the documented instruction/acknowledgment/commentary sequence."
  alias Parlora.{ContextUpdate, Event, ID}
  require Logger

  def start(session) do
    spec =
      Supervisor.child_spec({Task, fn -> run(session) end},
        id: {__MODULE__, session},
        restart: :temporary
      )

    Supervisor.start_child(OrderDesk.Supervisor, spec)
  end

  def run(session, options \\ []) do
    timeout_ms = Keyword.get(options, :timeout_ms, 5_000)
    monitor = Process.monitor(session)
    id = ID.new()

    progress_ms =
      Keyword.get(
        options,
        :progress_timeout_ms,
        Application.get_env(:order_desk, :greeting_progress_timeout_ms, 30_000)
      )

    with :ok <- Parlora.subscribe(session),
         :ok <-
           Parlora.expect_progress(session, id, progress_ms,
             until: :conversation,
             on_timeout: :close
           ),
         :ok <-
           OrderDesk.Provider.append_context(session, %ContextUpdate{
             id: id,
             kind: :instruction,
             provider_generation: 0,
             content:
               "Speak English. Greet the caller immediately without waiting for them to speak: Hi, I can help check an order. Then pause and listen."
           }) do
      Logger.info("Greeting instruction submitted; awaiting provider acknowledgment")
      await_ack(session, monitor, id, false, System.monotonic_time(:millisecond) + timeout_ms)
    else
      _error ->
        Parlora.resolve_progress(session, id, :cancelled)
        Logger.warning("Greeting instruction could not be submitted")
    end
  catch
    :exit, _closed -> :ok
  end

  defp await_ack(session, monitor, id, speech?, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:parlora_event, %Event{type: :context_submitted, command_id: ^id}} ->
        Logger.info(
          "Greeting submitted without remote acknowledgment; conversational progress remains monitored"
        )

      {:parlora_event, %Event{type: :context_acknowledged, command_id: ^id}} ->
        Logger.info("Greeting instruction acknowledged; this is not playback confirmation")

        unless speech? do
          result =
            Parlora.append_context(session, %ContextUpdate{
              id: ID.new(),
              kind: :speakable,
              provider_generation: 0,
              content: "Begin the conversation now, following the opening instructions."
            })

          case result do
            :ok -> Logger.info("Greeting opening prompt submitted")
            _error -> Logger.warning("Greeting opening prompt could not be submitted")
          end
        end

      {:parlora_event, %Event{type: :context_rejected, command_id: ^id}} ->
        Parlora.resolve_progress(session, id, :cancelled)
        Logger.warning("Greeting instruction was rejected")

      {:parlora_event, %Event{type: :transcript_delta}} ->
        await_ack(session, monitor, id, true, deadline)

      {:DOWN, ^monitor, :process, ^session, _reason} ->
        :ok

      _event ->
        await_ack(session, monitor, id, speech?, deadline)
    after
      remaining -> Logger.warning("Greeting acknowledgment timed out")
    end
  end
end
