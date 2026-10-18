defmodule Parlora.Validation.Pipecat.Policy do
  @behaviour Parlora.ContextPolicy
  @impl true
  def interpret(_snapshot, trigger, _options) do
    {:ok, [%Parlora.ContextDecision{kind: :no_action, delegation_id: trigger.delegation_id}]}
  end
end

defmodule Parlora.Validation.Pipecat do
  alias Parlora.{AudioFrame, Event}
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, MemoryProvider}
  alias Parlora.Validation.Pipecat.Policy

  @tail_ms 3_000
  @instructions """
  Listen to the caller in English. Keep any replies very brief.
  Allow silence without prompting. Do not greet before the caller speaks.
  No backend tools are available. Do not delegate requests.
  """

  def main(args) do
    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          output: :string,
          limit: :integer,
          concurrency: :integer,
          diagnostics: :string,
          skip_successes_from: [:string, :keep],
          live: :boolean
        ]
      )

    unless opts[:live], do: raise("Pass --live to make billable provider requests")
    diagnostic_mode = Keyword.get(opts, :diagnostics, "off")
    unless diagnostic_mode in ["off", "missing", "all"], do: raise("Invalid diagnostics mode")
    key = System.fetch_env!("OPENAI_API_KEY")
    manifest_path = Path.expand(Keyword.fetch!(opts, :manifest))
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    limit = Keyword.get(opts, :limit, 20)
    concurrency = Keyword.get(opts, :concurrency, 4)
    unless limit in 1..1000 and concurrency in 1..8, do: raise("Invalid limits")
    samples = Enum.take(manifest["samples"], limit)
    unless length(samples) == limit, do: raise("Insufficient manifest samples")
    manifest_hash = hash(File.read!(manifest_path))
    prior_runs = Keyword.get_values(opts, :skip_successes_from) |> Enum.map(&Path.expand/1)
    preserved = preserved_successes(prior_runs, manifest_hash)
    samples = Enum.reject(samples, &Map.has_key?(preserved, &1["sample_id"]))
    if samples == [], do: raise("No remaining samples; no provider requests made")
    output = Path.expand(Keyword.fetch!(opts, :output))
    :ok = File.mkdir(output)
    {git_revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {git_status, 0} = System.cmd("git", ["status", "--porcelain"])

    metadata = %{
      schema_version: 1,
      dataset: manifest["dataset"],
      dataset_revision: manifest["revision"],
      manifest_sha256: manifest_hash,
      runner_sha256: hash(File.read!(__ENV__.file)),
      git_revision: String.trim(git_revision),
      working_tree_dirty: git_status != "",
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      mode: "live",
      path: "recorded_pcm -> MemoryChannel -> Parlora.AudioPipeline -> GPT-Live-1",
      model_requested: "gpt-live-1",
      instructions: @instructions,
      tail_ms: @tail_ms,
      concurrency: concurrency,
      diagnostics: diagnostic_mode,
      prior_runs: prior_runs,
      preserved_successes: preserved,
      planned_ids: Enum.map(samples, & &1["sample_id"]),
      timing_origin: "first PCM injection; deadlines relative to nominal clip end, not speech end"
    }

    metadata =
      if diagnostic_mode == "off" do
        metadata
      else
        sources = [
          {Parlora.Providers.OpenAI, "provider.ex"},
          {Parlora.Providers.OpenAI.Diagnostics, "provider-diagnostics.ex"}
        ]

        hashes =
          Map.new(sources, fn {module, name} ->
            source = module.module_info(:compile)[:source] |> List.to_string() |> File.read!()
            File.write!(Path.join(output, name), source)
            {name, hash(source)}
          end)

        Map.put(metadata, :diagnostic_source_hashes, hashes)
      end

    write_json(Path.join(output, "run.json"), metadata)
    File.copy!(__ENV__.file, Path.join(output, "runner.ex"))
    File.copy!(manifest_path, Path.join(output, "manifest.json"))

    # Stop scheduling new groups on an infrastructure failure. Preserve every attempt.
    result =
      samples
      |> Enum.chunk_every(concurrency)
      |> Enum.reduce_while(:ok, fn group, :ok ->
        results =
          Task.async_stream(
            group,
            fn sample ->
              result =
                run_sample(sample, Path.dirname(manifest_path), key, :live,
                  diagnostics: diagnostic_mode,
                  diagnostic_dir: Path.join(output, "diagnostics")
                )

              write_json(Path.join(output, sample["sample_id"] <> ".json"), result)
              IO.puts(Jason.encode!(Map.take(result, [:sample_id, :status, :error])))
              result
            end,
            max_concurrency: concurrency,
            timeout: :infinity
          )
          |> Enum.to_list()

        if Enum.all?(results, &match?({:ok, %{status: "ok"}}, &1)),
          do: {:cont, :ok},
          else: {:halt, :failed}
      end)

    write_json(Path.join(output, "completion.json"), %{
      status: result,
      active_sessions: DynamicSupervisor.count_children(Parlora.Sessions).active,
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    if result != :ok, do: System.halt(1)
  end

  def preserved_successes(paths, manifest_hash) do
    Enum.reduce(paths, %{}, fn path, found ->
      metadata = path |> Path.join("run.json") |> File.read!() |> Jason.decode!()

      unless metadata["manifest_sha256"] == manifest_hash and
               metadata["instructions"] == @instructions and
               metadata["tail_ms"] == @tail_ms and metadata["mode"] == "live",
             do: raise("Prior run configuration does not match")

      Enum.reduce(metadata["planned_ids"], found, fn id, acc ->
        result_path = Path.join(path, id <> ".json")

        if File.exists?(result_path) do
          bytes = File.read!(result_path)
          result = Jason.decode!(bytes)

          if result["sample_id"] == id and result["status"] == "ok" and
               get_in(result, ["close", "cleaned_up"]) and
               get_in(result, ["close", "finalized"]),
             do: Map.put(acc, id, %{path: result_path, sha256: hash(bytes)}),
             else: acc
        else
          acc
        end
      end)
    end)
  end

  def run_sample(sample, root, key, mode \\ :live, options \\ []) do
    pcm = File.read!(Path.join(root, sample["pcm_path"]))

    unless hash(pcm) == sample["pcm_sha256"] and byte_size(pcm) == sample["pcm_bytes"],
      do: raise("PCM integrity mismatch")

    Process.delete(:pipecat_diagnostics)
    capture? = Keyword.get(options, :diagnostics, "off") != "off"

    provider =
      if mode == :live,
        do: {Parlora.Providers.OpenAI, api_key: key, diagnostic_sink: if(capture?, do: self())},
        else: {MemoryProvider, observer: self()}

    result =
      case Parlora.start_session(
             channel: {MemoryChannel, observer: self()},
             provider: provider,
             backend: {FakeBackend, observer: self()},
             context_policy: {Policy, []},
             event_sink: self(),
             instructions: @instructions
           ) do
        {:ok, session} ->
          result =
            try do
              {channel, fake_provider} = ready(now() + 16_000_000, nil, nil)
              :ok = Parlora.control(session, {:suppress_output, true})
              started = now() + 50_000
              owner = self()
              {feeder, monitor} = spawn_monitor(fn -> feed(owner, channel, pcm, started) end)

              if fake_provider do
                Process.send_after(self(), {:fake_transcript, fake_provider}, 100)
              end

              try do
                state = collect(%{events: [], pacing: nil}, started, fake_provider, monitor)
                close = close_session(session, started)

                Map.merge(state, %{
                  sample_id: sample["sample_id"],
                  mode: mode,
                  status:
                    cond do
                      Map.has_key?(state, :error) -> "failed"
                      close.cleaned_up and state.pacing.max_late_ms <= 100 -> "ok"
                      true -> "invalid"
                    end,
                  duration_ms: byte_size(pcm) / 48,
                  input_started_at_us: started,
                  events: Enum.reverse(state.events),
                  close: close
                })
              after
                if Process.alive?(feeder), do: Process.exit(feeder, :kill)
                Process.demonitor(monitor, [:flush])
              end
            rescue
              error ->
                %{
                  sample_id: sample["sample_id"],
                  status: "failed",
                  error: Exception.message(error)
                }
            catch
              :exit, _reason ->
                %{sample_id: sample["sample_id"], status: "failed", error: "adapter_exit"}
            after
              if Process.alive?(session), do: close_session(session)
            end

          Map.put_new(result, :close, %{cleaned_up: not Process.alive?(session), finalized: false})

        {:error, _reason} ->
          %{sample_id: sample["sample_id"], status: "failed", error: "session_start_failed"}
      end

    retain_diagnostics(result, sample, pcm, options)
  end

  defp ready(deadline, channel, provider) do
    receive do
      {:adapter, :channel, pid} ->
        ready(deadline, pid, provider)

      {:adapter, :provider, pid} ->
        ready(deadline, channel, pid)

      {:parlora_event, %Event{source: :session, type: :ready}} ->
        {channel, provider}

      {:parlora_event, %Event{type: :control_failed, payload: %{error: error}}} ->
        raise("Provider startup rejected: #{error.message}; #{inspect(error.details)}")

      {:parlora_event, %Event{type: :failed, payload: %{error: error}}} ->
        raise("Session failed before ready: #{error.message}; #{inspect(error.details)}")

      {:parlora_event, %Event{type: :closed, payload: payload}} ->
        raise("Session closed before ready: #{inspect(Map.take(payload, [:reason]))}")

      {:parlora_provider_diagnostics, report} ->
        Process.put(:pipecat_diagnostics, report)
        ready(deadline, channel, provider)

      _message ->
        ready(deadline, channel, provider)
    after
      max(0, div(deadline - now(), 1000)) -> raise("Session readiness timeout")
    end
  end

  defp feed(owner, channel, pcm, started) do
    data = pcm <> :binary.copy(<<0>>, @tail_ms * 48)

    pacing =
      feed_frames(data, channel, started, 0, 0, %{max_late_ms: 0, frame_count: 0, bytes: 0})

    sleep_until(started + div(byte_size(data) * 1_000_000, 48_000))
    send(owner, {:feed_done, pacing})
  end

  defp feed_frames(<<>>, _channel, _started, _offset, _sequence, stats), do: stats

  defp feed_frames(data, channel, started, offset, sequence, stats) do
    count = min(960, byte_size(data))
    <<chunk::binary-size(^count), rest::binary>> = data
    target = started + div(offset * 1_000_000, 48_000)
    sleep_until(target)
    late_ms = max(0, now() - target) / 1000
    if late_ms > 100, do: exit(:pacing_failed)

    frame =
      AudioFrame.pcm(chunk, "pipecat", sequence, timestamp_us: target, clock: :local_monotonic)

    :ok = MemoryAudio.audio(channel, frame)

    next = %{
      max_late_ms: max(stats.max_late_ms, late_ms),
      frame_count: stats.frame_count + 1,
      bytes: stats.bytes + count
    }

    feed_frames(rest, channel, started, offset + count, sequence + 1, next)
  end

  defp collect(state, started, fake_provider, monitor) do
    if fake_provider, do: MemoryAudio.drain(fake_provider)

    receive do
      {:feed_done, pacing} ->
        %{state | pacing: pacing}

      {:DOWN, ^monitor, :process, _pid, reason} ->
        Map.put(state, :error, "Audio feeder stopped: #{inspect(reason)}")

      {:fake_transcript, pid} ->
        :ok =
          MemoryAudio.inject(pid, :transcript_delta, %{
            speaker: :user,
            delta: "offline harness check",
            start_ms: 0,
            end_ms: 100
          })

        collect(state, started, fake_provider, monitor)

      {:parlora_event,
       %Event{type: :transcript_delta, payload: %{speaker: :user} = payload} = event} ->
        record = %{
          at_ms: (event.observed_at_us - started) / 1000,
          delta: payload.delta,
          provider_start_ms: payload.start_ms,
          provider_end_ms: payload.end_ms
        }

        collect(%{state | events: [record | state.events]}, started, fake_provider, monitor)

      {:parlora_event, %Event{type: type, source: source, payload: payload}}
      when type in [:failed, :closed, :audio_discontinuity] ->
        details = Map.take(payload, [:reason, :cause, :direction, :finalized?])

        details =
          case payload do
            %{error: error} ->
              Map.put(details, :error, Map.take(error, [:code, :message, :details]))

            _other ->
              details
          end

        Map.merge(state, %{
          error: "Session interrupted: #{type}",
          failure_source: source,
          failure_details: details
        })

      {:parlora_provider_diagnostics, report} ->
        Process.put(:pipecat_diagnostics, report)
        collect(state, started, fake_provider, monitor)

      _message ->
        collect(state, started, fake_provider, monitor)
    after
      10 ->
        if now() - started > 25_000_000, do: raise("Clip observation timeout")
        collect(state, started, fake_provider, monitor)
    end
  end

  defp close_session(session, started \\ nil) do
    monitor = Process.monitor(session)
    if Process.alive?(session), do: Parlora.close(session, :finish)
    await_close(session, monitor, now() + 7_000_000, false, started, [])
  end

  defp await_close(session, monitor, deadline, finalized, started, late_events) do
    receive do
      {:parlora_event, %Event{source: :session, type: :closed, payload: payload}} ->
        await_close(
          session,
          monitor,
          deadline,
          Map.get(payload, :finalized?, false),
          started,
          late_events
        )

      {:parlora_event,
       %Event{type: :transcript_delta, payload: %{speaker: :user} = payload} = event}
      when is_integer(started) ->
        late = %{
          at_ms: (event.observed_at_us - started) / 1000,
          delta: payload.delta,
          provider_start_ms: payload.start_ms,
          provider_end_ms: payload.end_ms
        }

        await_close(session, monitor, deadline, finalized, started, [late | late_events])

      {:DOWN, ^monitor, :process, ^session, _reason} ->
        %{cleaned_up: true, finalized: finalized, late_events: Enum.reverse(late_events)}

      {:parlora_provider_diagnostics, report} ->
        Process.put(:pipecat_diagnostics, report)
        await_close(session, monitor, deadline, finalized, started, late_events)

      _message ->
        await_close(session, monitor, deadline, finalized, started, late_events)
    after
      max(0, div(deadline - now(), 1000)) ->
        Process.demonitor(monitor, [:flush])
        %{cleaned_up: false, finalized: finalized, late_events: Enum.reverse(late_events)}
    end
  end

  @doc false
  def retain_diagnostics(result, sample, pcm, options) do
    mode = Keyword.get(options, :diagnostics, "off")

    if mode == "off" do
      result
    else
      report =
        Process.delete(:pipecat_diagnostics) ||
          receive do
            {:parlora_provider_diagnostics, report} -> report
          after
            100 -> nil
          end

      missing? =
        not Enum.any?(Map.get(result, :events, []), fn event ->
          String.trim(event.delta) != "" and event.at_ms <= byte_size(pcm) / 48 + @tail_ms
        end)

      cond do
        is_nil(report) ->
          Map.put(result, :diagnostics, %{state: "unavailable"})

        mode == "all" or result.status != "ok" or missing? ->
          directory = Path.join(Keyword.fetch!(options, :diagnostic_dir), sample["sample_id"])
          File.mkdir_p!(Path.dirname(directory))
          File.mkdir!(directory)
          File.chmod!(directory, 0o700)
          audio = report.pcm
          File.write!(Path.join(directory, "wire.pcm"), audio)
          File.chmod!(Path.join(directory, "wire.pcm"), 0o600)

          metadata =
            report
            |> Map.delete(:pcm)
            |> Map.merge(%{
              sample_id: sample["sample_id"],
              audio_format: "mono PCM16LE 24000 Hz",
              input_started_at_us: result[:input_started_at_us],
              source_pcm_sha256: sample["pcm_sha256"],
              wire_pcm_sha256: hash(audio),
              expected_accepted_bytes: byte_size(pcm) + @tail_ms * 48,
              expected_accepted_sha256: hash(pcm <> :binary.copy(<<0>>, @tail_ms * 48)),
              missing_at_deadline: missing?,
              late_events: get_in(result, [:close, :late_events]) || []
            })

          write_json(Path.join(directory, "capture.json"), metadata)
          File.chmod!(Path.join(directory, "capture.json"), 0o600)
          Map.put(result, :diagnostics, %{state: "retained", directory: directory})

        true ->
          Map.put(result, :diagnostics, %{state: "discarded_success"})
      end
    end
  end

  defp sleep_until(target) do
    remaining = target - now()

    if remaining > 0 do
      Process.sleep(div(remaining + 999, 1000))
      sleep_until(target)
    end
  end

  defp now, do: System.monotonic_time(:microsecond)
  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp write_json(path, data), do: File.write!(path, Jason.encode!(data, pretty: true) <> "\n")
end
