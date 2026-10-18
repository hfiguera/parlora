defmodule Parlora.Session.Health do
  @moduledoc false
  alias Parlora.{CommandLog, Error}

  def new(limit) do
    %{
      audio: :atomics.new(6, signed: true),
      observations: %{},
      expectation: nil,
      timer: nil,
      token: nil,
      commands: %CommandLog{limit: limit}
    }
  end

  # Audio never sends per-frame messages through the session coordinator.
  # Each direction has one writer. Reads are approximate concurrent observations.
  def transferred(nil, _direction, _frame), do: :ok

  def transferred(counters, direction, frame) do
    index = if direction == :input, do: 1, else: 4
    :atomics.add(counters, index, 1)
    :atomics.add(counters, index + 1, byte_size(frame.data))
    :atomics.put(counters, index + 2, System.monotonic_time(:microsecond))
  end

  def snapshot(health) do
    %{
      input_forwarded: audio(health.audio, 1),
      output_forwarded: audio(health.audio, 4),
      observations: health.observations,
      expectation: health.expectation
    }
  end

  def expect(health, id, timeout_ms, options) do
    case config(timeout_ms, options) do
      {:ok, config} ->
        case CommandLog.admit(health.commands, id, config) do
          {:duplicate, _log} -> {:ok, health}
          {:new, log} -> arm(health, log, id, config)
          error -> {error, health}
        end

      error ->
        {error, health}
    end
  end

  def resolve(%{expectation: %{id: id, status: status}} = health, id, outcome)
      when outcome in [:completed, :cancelled] do
    cond do
      status == outcome ->
        {:ok, health}

      status != :pending ->
        {Error.tuple(:invalid_argument, "Expectation is already terminal"), health}

      due?(health) ->
        {Error.tuple(:timeout, "Progress deadline has elapsed"), health}

      true ->
        {:ok, finish(health, outcome)}
    end
  end

  def resolve(health, _id, _outcome),
    do: {Error.tuple(:invalid_argument, "Unknown expectation or invalid outcome"), health}

  def observe(health, event) do
    health =
      if event.source == :provider,
        do: record(health, :provider_event, event.observed_at_us),
        else: health

    case observation(event) do
      nil -> health
      kind -> health |> record(kind, event.observed_at_us) |> satisfy(kind, event.observed_at_us)
    end
  end

  def expire(%{token: token, expectation: %{status: :pending} = expectation} = health, token)
      when not is_nil(token) do
    if due?(health) do
      {expectation.on_timeout, finish(health, :timed_out)}
    else
      if health.timer, do: Process.cancel_timer(health.timer)

      remaining =
        max(1, div(expectation.deadline_at_us - System.monotonic_time(:microsecond) + 999, 1_000))

      timer = Process.send_after(self(), {:progress_deadline, token}, remaining)
      {:none, %{health | timer: timer}}
    end
  end

  def expire(health, _token), do: {:none, health}

  def close(%{expectation: %{status: :pending}} = health), do: finish(health, :cancelled)
  def close(health), do: health

  defp arm(%{expectation: %{status: :pending}} = health, _log, _id, _config),
    do: {Error.tuple(:backpressure, "A progress expectation is already pending"), health}

  defp arm(health, log, id, config) do
    now = System.monotonic_time(:microsecond)
    token = make_ref()
    timer = Process.send_after(self(), {:progress_deadline, token}, config.timeout_ms)

    expectation =
      Map.merge(config, %{
        id: id,
        status: :pending,
        started_at_us: now,
        deadline_at_us: now + config.timeout_ms * 1_000
      })

    {:ok, %{health | expectation: expectation, commands: log, timer: timer, token: token}}
  end

  defp finish(health, status) do
    if health.timer, do: Process.cancel_timer(health.timer)

    expectation =
      Map.merge(health.expectation, %{
        status: status,
        resolved_at_us: System.monotonic_time(:microsecond)
      })

    %{health | expectation: expectation, timer: nil, token: nil}
  end

  defp satisfy(%{expectation: %{status: :pending, until: until} = expected} = health, kind, at_us)
       when until == kind or
              (until == :conversation and kind in [:assistant_caption, :user_caption, :delegation]) do
    if at_us >= expected.started_at_us and not due?(health),
      do: finish(health, :observed),
      else: health
  end

  defp satisfy(health, _kind, _at_us), do: health

  defp due?(health), do: System.monotonic_time(:microsecond) >= health.expectation.deadline_at_us

  defp config(timeout, options)
       when is_integer(timeout) and timeout in 1..300_000 and is_list(options) do
    if Keyword.keyword?(options) and
         Enum.all?(Keyword.keys(options), &(&1 in [:until, :on_timeout])) and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
         Keyword.get(options, :until, :assistant_caption) in [
           :assistant_caption,
           :user_caption,
           :delegation,
           :conversation,
           :explicit
         ] and
         Keyword.get(options, :on_timeout, :notify) in [:notify, :close] do
      {:ok,
       %{
         timeout_ms: timeout,
         until: Keyword.get(options, :until, :assistant_caption),
         on_timeout: Keyword.get(options, :on_timeout, :notify)
       }}
    else
      invalid_config()
    end
  end

  defp config(_timeout, _options), do: invalid_config()
  defp invalid_config, do: Error.tuple(:invalid_argument, "Invalid progress deadline or options")

  defp observation(%{
         source: :provider,
         type: :transcript_delta,
         payload: %{speaker: speaker, delta: delta}
       })
       when is_binary(delta) and byte_size(delta) > 0 do
    if String.trim(delta) != "" do
      case speaker do
        :user -> :user_caption
        :assistant -> :assistant_caption
        _ -> nil
      end
    end
  end

  defp observation(%{source: :provider, type: :delegation_requested}), do: :delegation
  defp observation(%{source: :channel, type: :playback_observed}), do: :playback_event
  defp observation(_event), do: nil

  defp record(health, kind, at_us) do
    observation = Map.get(health.observations, kind, %{count: 0, last_at_us: at_us})
    observation = %{count: observation.count + 1, last_at_us: max(observation.last_at_us, at_us)}
    %{health | observations: Map.put(health.observations, kind, observation)}
  end

  defp audio(counters, index) do
    frames = :atomics.get(counters, index)

    %{
      frames: frames,
      bytes: :atomics.get(counters, index + 1),
      last_at_us: if(frames > 0, do: :atomics.get(counters, index + 2))
    }
  end
end
