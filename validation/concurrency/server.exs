# Loopback-only concurrency fixture. No model credentials or microphone.
defmodule ParloraConcurrency.Action do
  use Jido.Action,
    name: "concurrency_lookup",
    schema: [
      input: [type: :map, required: true],
      request_id: [type: :string],
      task_id: [type: :string],
      task_revision: [type: :integer]
    ]

  def run(params, _) do
    Process.sleep(200)
    {:ok, %{status: :completed, last_answer: %{marker: params.input.marker}}}
  end
end

defmodule ParloraConcurrency.Agent do
  use Jido.Agent,
    name: "concurrency_agent",
    schema: [status: [type: :atom, default: :idle], last_answer: [type: :map, default: %{}]],
    signal_routes: [{"parlora.request", ParloraConcurrency.Action}]
end

defmodule ParloraConcurrency.Policy do
  @behaviour Parlora.ContextPolicy
  alias Parlora.ContextDecision

  def interpret(snapshot, _, _) do
    case Enum.find(snapshot.transcripts, &(&1.speaker == :user)) do
      nil -> {:ok, []}
      %{delta: marker} -> {:ok, decide(snapshot, marker)}
    end
  end

  defp decide(snapshot, marker) do
    case Enum.to_list(snapshot.tasks) do
      [{_, %{input: %{marker: ^marker}}}] ->
        []

      [{id, task}] ->
        [
          %ContextDecision{
            kind: :supersede_task,
            task_id: id,
            expected_task_revision: task.revision,
            input: %{marker: marker}
          }
        ]

      [] ->
        case Enum.find(snapshot.pending_delegations, fn {_, d} -> d.status == :pending end) do
          {id, _} ->
            [%ContextDecision{kind: :start_task, delegation_id: id, input: %{marker: marker}}]

          nil ->
            []
        end
    end
  end
end

defmodule ParloraConcurrency.Provider do
  use GenServer
  use Parlora.AdapterClient
  @behaviour Parlora.Provider
  alias Parlora.{AudioFormat, Event}
  alias Parlora.Provider.OutputBuffer
  def start_link(init, options), do: GenServer.start_link(__MODULE__, {init, options})
  def append_context(pid, update), do: GenServer.call(pid, {:context, update})

  def init({init, options}) do
    tag = Keyword.fetch!(options, :tag)
    slot = Keyword.fetch!(options, :slot)
    send(ParloraConcurrency.Observer, {:provider, tag, self()})
    Event.emit(init, :provider, :ready, %{capabilities: caps(), format: %AudioFormat{}})

    tone =
      for n <- 0..479, into: <<>> do
        value = round(6000 * :math.sin(2 * :math.pi() * (100 + slot * 400) * n / 24_000))
        <<value::signed-little-16>>
      end

    {:ok,
     %{
       init: init,
       tag: tag,
       slot: slot,
       tone: tone,
       queue: OutputBuffer.new(init.limits),
       sequence: 0,
       captured: [],
       capture_bytes: 0,
       received_bytes: 0,
       queue_peak: 0,
       late_max_us: 0,
       deadline: nil,
       stalled: false,
       closed: false
     }}
  end

  defp caps do
    %Parlora.Provider.Capabilities{
      audio_formats: [%AudioFormat{}],
      full_duplex?: true,
      transcripts: [:user, :assistant],
      delegation_modes: [:client],
      context_update_kinds: [:speakable, :instruction]
    }
  end

  def handle_call(:capabilities, _, state), do: {:reply, {:ok, caps()}, state}

  def handle_call(:start, _, %{deadline: nil} = state) do
    send(self(), :produce)
    {:reply, :ok, %{state | deadline: System.monotonic_time(:microsecond)}}
  end

  def handle_call(:start, _, state), do: {:reply, :ok, state}

  def handle_call(:stall, _, state),
    do: {:reply, :ok, %{state | stalled: true, queue: OutputBuffer.new(state.init.limits)}}

  def handle_call(:sample, _, state),
    do:
      {:reply, Map.take(state, [:received_bytes, :queue_peak, :late_max_us, :capture_bytes]),
       state}

  def handle_call({:request, round}, _, state) do
    unless state.stalled do
      marker = "#{state.tag}:job#{round}"

      Event.emit(state.init, :provider, :transcript_delta, %{
        speaker: :user,
        delta: marker,
        start_ms: 0,
        end_ms: 1
      })

      Event.emit(state.init, :provider, :delegation_requested, %{
        id: "delegation",
        target: :client,
        offset_ms: 1
      })
    end

    {:reply, :ok, state}
  end

  def handle_call({:read, bytes}, _, state) do
    case OutputBuffer.read(
           state.queue,
           bytes,
           state.init.limits,
           System.monotonic_time(:microsecond)
         ) do
      {:ok, frames, queue} -> {:reply, {:ok, frames}, %{state | queue: queue}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:write, frame}, _, state) do
    {captured, bytes} =
      if state.capture_bytes < 1_440_000 do
        {[frame.data | state.captured], state.capture_bytes + byte_size(frame.data)}
      else
        {state.captured, state.capture_bytes}
      end

    {:reply, :ok,
     %{
       state
       | captured: captured,
         capture_bytes: bytes,
         received_bytes: state.received_bytes + byte_size(frame.data)
     }}
  end

  def handle_call({:context, update}, _, state) do
    Event.emit(state.init, :provider, :context_acknowledged, %{}, command_id: update.id)

    unless state.stalled do
      Event.emit(state.init, :provider, :transcript_delta, %{
        speaker: :assistant,
        delta: update.content,
        start_ms: 0,
        end_ms: 1
      })
    end

    {:reply, :ok, state}
  end

  def handle_call({:control, id, _}, _, state) do
    Event.emit(state.init, :provider, :control_completed, %{}, command_id: id)
    {:reply, :ok, state}
  end

  def handle_call({:close, id, _}, _, state) do
    save(state)
    Event.emit(state.init, :provider, :closed, %{finalized?: true}, command_id: id)
    {:reply, :ok, %{state | closed: true}}
  end

  def handle_call(:save, _, state),
    do:
      (
        save(state)
        {:reply, :ok, state}
      )

  def handle_info(:produce, %{closed: true} = state), do: {:noreply, state}

  def handle_info(:produce, state) do
    now = System.monotonic_time(:microsecond)
    state = %{state | late_max_us: max(state.late_max_us, now - state.deadline)}

    state =
      if state.stalled do
        state
      else
        case OutputBuffer.push(state.queue, state.tone, state.init, state.sequence, now) do
          {:ok, {queue, sequence}} ->
            %{
              state
              | queue: queue,
                sequence: sequence,
                queue_peak: max(state.queue_peak, queue.bytes)
            }

          {:error, error} ->
            Event.emit(state.init, :provider, :failed, %{cause: error.code, error: error})
            %{state | stalled: true}
        end
      end

    deadline = state.deadline + 20_000
    Process.send_after(self(), :produce, max(1, div(deadline - now + 999, 1000)))
    {:noreply, %{state | deadline: deadline}}
  end

  defp save(state) do
    path = Path.join(System.fetch_env!("CONCURRENCY_OUTPUT"), state.tag <> "-input.pcm")
    File.write!(path, Enum.reverse(state.captured))
    File.chmod!(path, 0o600)

    send(
      ParloraConcurrency.Observer,
      {:provider_final, state.tag,
       Map.take(state, [:received_bytes, :capture_bytes, :queue_peak, :late_max_us])}
    )
  end
end

defmodule ParloraConcurrency.Observer do
  use GenServer
  alias Parlora.Event
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :sample, 200)
    {:ok, %{sessions: %{}, providers: %{}, vm: [], tracked: MapSet.new()}}
  end

  def watch(tag, pid), do: GenServer.call(__MODULE__, {:watch, tag, pid})

  def handle_call({:watch, tag, pid}, _, state) do
    :ok = Parlora.subscribe(pid)
    id = Parlora.snapshot(pid).session_id
    Process.monitor(pid)

    entry = %{
      pid: pid,
      id: id,
      closed: false,
      captions: [],
      results: [],
      jobs: [],
      failure: nil,
      health: nil,
      metrics: %{},
      submitted_at: %{},
      response_ms: [],
      samples: []
    }

    {:reply, :ok, %{state | sessions: Map.put(state.sessions, tag, entry)}}
  end

  def handle_call(:report, _, state) do
    sessions =
      Map.new(state.sessions, fn {tag, e} -> {tag, Map.drop(e, [:pid, :submitted_at])} end)

    reply = %{
      sessions: sessions,
      vm: Enum.reverse(state.vm),
      active: DynamicSupervisor.count_children(Parlora.Sessions).active,
      gate_active: OrderDesk.BrowserGate.count(),
      tracked_alive: Enum.count(state.tracked, &Process.alive?/1),
      beam_pid: System.pid()
    }

    {:reply, reply, state}
  end

  def handle_call({:command, tag, action, round}, _, state) do
    e = state.sessions[tag]
    provider = state.providers[tag]

    reply =
      case action do
        "start" ->
          GenServer.call(provider, :start)

        "request" ->
          GenServer.call(provider, {:request, round})

        "stall" ->
          :ok =
            Parlora.expect_progress(e.pid, "stall", 1500,
              until: :assistant_caption,
              on_timeout: :close
            )

          GenServer.call(provider, :stall)

        "disconnect" ->
          :ok = GenServer.call(provider, :save)
          Process.exit(provider, :kill)
          :ok
      end

    {:reply, reply, state}
  end

  def handle_info({:provider, tag, pid}, state),
    do: {:noreply, %{state | providers: Map.put(state.providers, tag, pid)}}

  def handle_info({:provider_final, tag, metrics}, state),
    do: {:noreply, put_in(state.sessions[tag].metrics, metrics)}

  def handle_info({:DOWN, _, :process, pid, _}, state) do
    sessions =
      Map.new(state.sessions, fn {tag, e} ->
        {tag, if(e.pid == pid, do: %{e | closed: true}, else: e)}
      end)

    {:noreply, %{state | sessions: sessions}}
  end

  def handle_info({:parlora_event, %Event{} = event}, state) do
    case Enum.find(state.sessions, fn {_, e} -> e.id == event.session_id end) do
      {tag, e} -> {:noreply, put_in(state.sessions[tag], record(e, event))}
      nil -> {:noreply, state}
    end
  end

  def handle_info(:sample, state) do
    now = System.monotonic_time(:microsecond)
    pids = tree(Parlora.Sessions)
    {runtime, _} = :erlang.statistics(:runtime)

    vm = %{
      at_us: now,
      beam_bytes: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count),
      cpu_ms: runtime,
      active: DynamicSupervisor.count_children(Parlora.Sessions).active,
      max_mailbox:
        Enum.reduce(pids, 0, fn p, n ->
          case Process.info(p, :message_queue_len) do
            {:message_queue_len, k} -> max(n, k)
            _ -> n
          end
        end)
    }

    sessions =
      Map.new(state.sessions, fn {tag, e} ->
        if e.closed do
          {tag, e}
        else
          status = Parlora.status(e.pid)

          sample =
            case status do
              %{health: h} ->
                %{
                  at_us: now,
                  input_bytes: h.input_forwarded.bytes,
                  output_bytes: h.output_forwarded.bytes
                }

              _ ->
                %{at_us: now}
            end

          {tag, %{e | samples: Enum.take([sample | e.samples], 300)}}
        end
      end)

    Process.send_after(self(), :sample, 200)

    {:noreply,
     %{
       state
       | sessions: sessions,
         vm: Enum.take([vm | state.vm], 3000),
         tracked: Enum.reduce(pids, state.tracked, &MapSet.put(&2, &1))
     }}
  end

  defp tree(supervisor) do
    Supervisor.which_children(supervisor)
    |> Enum.flat_map(fn
      {_, pid, :supervisor, _} when is_pid(pid) -> [pid | tree(pid)]
      {_, pid, _, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  catch
    :exit, _ -> []
  end

  defp record(e, %{type: :transcript_delta, payload: p, observed_at_us: at}) do
    latency =
      if p.speaker == :assistant do
        case e.submitted_at[p.delta] do
          nil -> []
          t -> [(at - t) / 1000]
        end
      else
        []
      end

    %{
      e
      | captions: Enum.take(e.captions ++ [Map.take(p, [:speaker, :delta])], -64),
        response_ms: e.response_ms ++ latency
    }
  end

  defp record(e, %{type: :task_submitted, payload: %{request: r}, observed_at_us: at}),
    do: %{
      e
      | jobs: e.jobs ++ [%{id: r.id, marker: r.input.marker}],
        submitted_at: Map.put(e.submitted_at, r.input.marker, at)
    }

  defp record(e, %{type: :request_completed, payload: result}),
    do: %{e | results: e.results ++ [result.summary]}

  defp record(e, %{type: :failed, payload: payload}),
    do: %{e | failure: Map.take(payload, [:cause])}

  defp record(e, %{source: :session, type: :closed, payload: p}), do: %{e | health: p.health}
  defp record(e, _), do: e
end

defmodule ParloraConcurrency.Server do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "<button id='start'>Start</button><script src='/client.js'></script>")
  end

  get "/client.js" do
    conn
    |> put_resp_content_type("text/javascript")
    |> send_resp(200, File.read!(Path.join(__DIR__, "client.js")))
  end

  get "/state" do
    report = GenServer.call(ParloraConcurrency.Observer, :report)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(report))
  end

  post "/command/:tag/:action/:round" do
    :ok =
      GenServer.call(
        ParloraConcurrency.Observer,
        {:command, tag, action, String.to_integer(round)}
      )

    send_resp(conn, 200, "ok")
  end

  get "/socket/:slot/:tag" do
    slot = String.to_integer(slot)

    if slot not in 1..4 or not Regex.match?(~r/^[a-z0-9-]{1,40}$/, tag),
      do: raise("Invalid fixture identity")

    Parlora.Channels.Browser.Signaling.upgrade(conn,
      start_session: fn channel ->
        {:ok, session} =
          Parlora.start_session(
            channel: channel,
            provider: {ParloraConcurrency.Provider, tag: tag, slot: slot},
            backend:
              {Parlora.Backends.Jido,
               agent: ParloraConcurrency.Agent,
               agent_options: [jido: OrderDesk.Jido],
               result: fn %{status: status, result: result} ->
                 %{status: status, summary: result.marker, facts: result}
               end},
            context_policy: {ParloraConcurrency.Policy, []},
            context: %{fixture_identity: tag},
            event_sink: self()
          )

        :ok = ParloraConcurrency.Observer.watch(tag, session)
        {:ok, session}
      end
    )
  end

  get "/gate" do
    Parlora.Channels.Browser.Signaling.upgrade(conn,
      start_session: fn channel -> OrderDesk.BrowserGate.start_session(channel) end
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

Logger.configure(level: :warning)
Application.put_env(:order_desk, :browser_offline, true)
# This offline fixture declares real Jido as its backend, including admission
# sessions. The consumer may include other optional backend dependencies.
Application.put_env(:order_desk, :backend, :jido)
{:ok, _} = ParloraConcurrency.Observer.start_link([])

{:ok, _} =
  Bandit.start_link(
    plug: ParloraConcurrency.Server,
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.fetch_env!("PORT"))
  )

IO.puts("CONCURRENCY_READY")
Process.sleep(:infinity)
