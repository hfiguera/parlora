defmodule OrderDesk.Smoke do
  @moduledoc "Runs the same public-API scenario under Mix and in an assembled release."
  alias OrderDesk.ScriptedProvider
  alias Parlora.Event

  def run(channel_options \\ [device: :synthetic]) do
    previous = Application.get_env(:order_desk, :lookup_delays)
    Application.put_env(:order_desk, :lookup_delays, %{"123" => 1_000, "124" => 50})

    try do
      scenario(channel_options)
    after
      if previous,
        do: Application.put_env(:order_desk, :lookup_delays, previous),
        else: Application.delete_env(:order_desk, :lookup_delays)
    end
  end

  defp scenario(channel_options) do
    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, channel_options},
        {ScriptedProvider, observer: self()},
        context: %{customer_id: "consumer-fixture"}
      )

    ref = Process.monitor(session)

    try do
      provider =
        receive do
          {:scripted_provider, pid} -> pid
        after
          5_000 -> raise "Provider startup timed out"
        end

      provider_ref = Process.monitor(provider)
      event(:session, :ready)
      %{application_context: %{customer_id: "consumer-fixture"}} = Parlora.snapshot(session)
      :ok = ScriptedProvider.say(provider, "Check order 123.")
      :ok = ScriptedProvider.delegate(provider, "consumer-123")
      first = event(:session, :task_submitted).payload.request
      :ok = ScriptedProvider.say(provider, " Actually, order 124.")
      second = event(:session, :task_submitted).payload.request
      true = second.task_id == first.task_id
      2 = second.task_revision
      :ok = ScriptedProvider.delegate(provider, "consumer-124")
      :ok = ScriptedProvider.delegate(provider, "consumer-124")

      receive do
        {:context, %{task_revision: 2, content: content}} ->
          true = content =~ "124"
          true = content =~ "out for delivery"
      after
        5_000 -> raise "Current result did not reach provider"
      end

      event(:session, :stale_result)
      %{jobs: jobs} = Parlora.status(session)
      2 = map_size(jobs)
      %{delivery: :stale} = Map.fetch!(jobs, first.id)
      %{delivery: :accepted} = Map.fetch!(jobs, second.id)
      true = ScriptedProvider.capture_bytes(provider) > 0
      handed_off(0)
      :ok = Parlora.control(session, {:suppress_output, true}, "consumer-stop")
      :ok = Parlora.control(session, {:clear_output, :next}, "consumer-clear")
      :ok = Parlora.control(session, {:suppress_output, false}, "consumer-resume")
      handed_off(1)
      :ok = Parlora.close(session, :finish)
      closed = event(:session, :closed)
      true = closed.payload.finalized?

      receive do
        {:DOWN, ^ref, :process, ^session, :normal} -> :ok
      after
        5_000 -> raise "Session resources remained alive"
      end

      receive do
        {:DOWN, ^provider_ref, :process, ^provider, _reason} -> :ok
      after
        5_000 -> raise "Provider resources remained alive"
      end

      report = %{
        current_order: "124",
        jobs: map_size(jobs),
        stale_result: true,
        provider_acknowledged: true,
        native_audio: true,
        finalized: true
      }

      IO.inspect(report, label: "CONSUMER_SMOKE")
      report
    after
      if Process.alive?(session), do: Parlora.close(session)
      Process.demonitor(ref, [:flush])
    end
  end

  defp handed_off(epoch) do
    receive do
      {:parlora_event,
       %Event{
         source: :channel,
         type: :playback_observed,
         payload: %{stage: :handed_off, epoch: ^epoch}
       }} ->
        :ok
    after
      5_000 -> raise "Missing native handoff for epoch #{epoch}"
    end
  end

  defp event(source, type) do
    receive do
      {:parlora_event, %Event{source: ^source, type: ^type} = event} -> event
      {:parlora_event, %Event{type: :failed}} -> raise "Adapter failed"
    after
      5_000 -> raise "Missing #{source} #{type}"
    end
  end
end
