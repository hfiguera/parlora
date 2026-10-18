defmodule OrderDesk.Progress do
  @moduledoc "Console diagnostics for the example; no transcript or result contents."

  def event(%{type: :delegation_pending, payload: payload}),
    do: "Delegation #{payload.delegation_id}: awaiting interpretation."

  def event(%{type: :delegation_associated, payload: payload}),
    do:
      "Delegation #{payload.id}: associated with task #{payload.task_id}, revision #{payload.task_revision}; no new job."

  def event(%{type: :context_wait_started, payload: payload}),
    do: "Waiting up to #{payload.recheck_after_ms} ms for more context."

  def event(%{type: :clarification_requested, command_id: id}),
    do: "Clarification submitted as #{id}; waiting for a usable order number."

  def event(%{type: :task_submitted, request_id: id, payload: %{admission: :ok}}),
    do: "Job #{id}: backend admission accepted."

  def event(%{type: :task_submitted, request_id: id}),
    do: "Job #{id}: backend admission failed or is uncertain. See /status."

  def event(%{type: :request_started, request_id: id}), do: "Job #{id}: running."
  def event(%{type: :task_queued, request_id: id}), do: "Job #{id}: queued for capacity."

  def event(%{type: type, request_id: id})
      when type in [:request_completed, :request_failed, :request_cancelled, :request_uncertain],
      do: "Job #{id}: #{type}."

  def event(%{type: :result_delivery, request_id: id, command_id: command, payload: payload}),
    do: "Result #{id}: #{payload.stage} (context #{command || "not submitted"})."

  def event(%{type: type, command_id: id})
      when type in [:context_acknowledged, :context_rejected],
      do: "Context #{id || "uncorrelated"}: #{type}; this is not playback confirmation."

  def event(%{type: type})
      when type in [:policy_failed, :policy_rejected, :admission_rejected, :failed, :adapter_down],
      do: "#{type}: work may be stalled. See /status."

  def event(_event), do: nil

  def audio(%{type: :audio_discontinuity} = event, started_at_us) do
    elapsed_ms = max(0, div(event.observed_at_us - started_at_us, 1_000))

    details =
      event.payload
      |> Map.take([
        :frames,
        :duration_us,
        :dropped_us,
        :dropped_bytes,
        :capacity_bytes,
        :max_age_ms,
        :epoch,
        :suppressed,
        :playback_buffer_ms,
        :direction,
        :poll_gap_us,
        :last_capture_us,
        :last_playback_us,
        :input_rate,
        :output_rate,
        :input_queue_frames,
        :output_queue_frames
      ])
      |> Enum.sort()
      |> Enum.map_join("; ", fn {key, value} -> "#{key}=#{value}" end)

    "Audio +#{elapsed_ms} ms: #{event.source}/#{event.payload.cause}; #{details}."
  end

  def audio(_event, _started_at_us), do: nil

  def mark(started_at_us) do
    elapsed_ms = max(0, div(System.monotonic_time(:microsecond) - started_at_us, 1_000))
    "Audio marker +#{elapsed_ms} ms: caller reported a gap near this time."
  end

  def status(snapshot) do
    lines = ["Session: #{snapshot.status}; interpretation: #{snapshot.interpretation}"]

    delegations =
      Enum.map(snapshot.delegations, fn {id, entry} ->
        "Delegation #{id}: #{entry.status}" <> association(entry) <> clarification(entry)
      end)

    jobs =
      Enum.map(snapshot.jobs, fn {id, job} ->
        execution =
          if job.status == :submitted and Map.has_key?(job, :started_at_us),
            do: :running,
            else: job.status

        "Job #{id}: #{execution}; revision #{job.task_revision}; current=#{job.current?}; result=#{Map.get(job, :delivery, :not_ready)}" <>
          clarification(job)
      end)

    playback =
      Enum.map([:queued, :handed_off], fn stage ->
        case snapshot.playback[stage] do
          nil ->
            "Audio #{stage}: not observed."

          observation ->
            age = max(0, div(snapshot.observed_at_us - observation.observed_at_us, 1_000))

            "Audio #{stage}: observed #{age} ms ago; epoch #{observation.epoch}; evidence=#{observation.evidence}."
        end
      end)

    Enum.join(
      lines ++
        delegations ++
        jobs ++
        playback ++
        [
          "Audio observations are session-wide, may include silence, and do not confirm that a specific result was heard."
        ],
      "\n"
    )
  end

  defp clarification(%{status: :claimed}), do: ""

  defp clarification(%{clarification: _}),
    do: "; clarification attempted; inspect context acknowledgment"

  defp clarification(%{context_wait: %{expired?: false}}), do: "; waiting for context recheck"
  defp clarification(_entry), do: ""

  defp association(%{task_id: id, task_revision: revision}),
    do: "; task #{id}, revision #{revision}"

  defp association(_entry), do: ""
end
