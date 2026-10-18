# Local protocol peer only. No OpenAI requests, credentials, or microphone.
Application.put_env(:order_desk, :backend, :jido)
Code.require_file(Path.expand("collector.exs", __DIR__))
source = File.read!(Path.expand("../acceptance/server.exs", __DIR__))

[modules, _] =
  String.split(source, "unless System.get_env(\"PARLORA_ACCEPTANCE_LIVE\")", parts: 2)

Code.compile_string(modules)

defmodule ParloraSilentSession.Peer do
  def init(_) do
    attempt = Agent.get_and_update(:fault_attempts, fn n -> {n, n + 1} end)

    {:ok,
     %{fault?: attempt in [0, 1], missing_ack?: attempt == 0, requested?: false, sequence: 0}}
  end

  def handle_in({json, _}, state) do
    command = Jason.decode!(json)

    case command["type"] do
      "session.start" ->
        reply(%{"type" => "session.started", "session" => %{"id" => "local-peer"}}, state)

      "session.close" ->
        reply(
          %{"type" => "session.closed", "reason" => "client_requested", "usage" => %{}},
          state
        )

      "session.input_audio.append" ->
        pcm = Base.decode64!(command["audio"])

        audible? =
          Enum.any?(for(<<sample::signed-little-16 <- pcm>>, do: sample), &(abs(&1) > 500))

        if not state.fault? and not state.requested? and audible? do
          send(
            self(),
            {:emit,
             %{
               "type" => "session.input_transcript.delta",
               "delta" => "Check order 124",
               "start_ms" => 1000,
               "end_ms" => 2000
             }}
          )

          send(
            self(),
            {:emit,
             %{
               "type" => "session.delegation.created",
               "delegation" => %{"id" => "lookup", "target" => "client"},
               "offset_ms" => 2000
             }}
          )

          {:ok, %{state | requested?: true}}
        else
          {:ok, state}
        end

      type
      when type in [
             "session.instructions.append",
             "session.commentary.append",
             "session.thinking.append"
           ] ->
        if state.missing_ack? do
          # First connection never acknowledges; second acknowledges but stays silent.
          {:ok, state}
        else
          if not state.fault? and command["content"] =~ "out for delivery" do
            send(
              self(),
              {:emit,
               %{
                 "type" => "session.output_transcript.delta",
                 "delta" => "Order 124 is out for delivery.",
                 "start_ms" => 3000,
                 "end_ms" => 3500
               }}
            )
          end

          reply(
            %{
              "type" => String.replace_suffix(type, ".append", ".appended"),
              "client_event_id" => command["event_id"]
            },
            state
          )
        end

      _ ->
        {:ok, state}
    end
  end

  def handle_info({:emit, message}, state), do: reply(message, state)
  defp reply(message, state), do: {:push, {:text, Jason.encode!(message)}, state}
end

defmodule ParloraSilentSession.PeerRoute do
  def init(opts), do: opts

  def call(conn, _),
    do: conn |> WebSockAdapter.upgrade(ParloraSilentSession.Peer, [], []) |> Plug.Conn.halt()
end

defmodule ParloraSilentSession.LocalProvider do
  use GenServer
  use Parlora.AdapterClient
  @behaviour Parlora.Provider
  alias Parlora.Providers.OpenAI
  def start_link(init, opts), do: GenServer.start_link(__MODULE__, {init, opts})
  def append_context(pid, update), do: OpenAI.append_context(pid, update)
  def output_buffer_status(pid), do: OpenAI.output_buffer_status(pid)

  def arm_output_ready(pid, reader, reference),
    do: OpenAI.arm_output_ready(pid, reader, reference)

  def init({init, opts}) do
    options = [
      api_key: "local-fixture",
      diagnostic_sink: opts[:sink],
      command_ack_timeout_ms: 1500
    ]

    {:ok, startup} = Parlora.Providers.OpenAI.Protocol.start(options, init.audio_format)
    {:ok, state, _} = OpenAI.init({init, options, startup})
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", opts[:port], protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/", [])
    {:ok, %{state | conn: conn, ref: ref}}
  end

  def handle_call(message, from, state), do: OpenAI.handle_call(message, from, state)
  def handle_info(message, state), do: OpenAI.handle_info(message, state)
  def terminate(reason, state), do: OpenAI.terminate(reason, state)
  def format_status(status), do: OpenAI.format_status(status)
end

defmodule ParloraSilentSession.Server do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/voice" do
    Parlora.Channels.Browser.Signaling.upgrade(conn,
      start_session: fn channel ->
        OrderDesk.start_session(
          channel,
          {ParloraSilentSession.LocalProvider,
           port: Application.fetch_env!(:order_desk, :fault_peer_port),
           sink: Process.whereis(ParloraSilentSession.Collector)},
          context: %{actor: "offline", customer: "demo"},
          context_policy:
            {OrderDesk.AppPolicy, classify: fn _ -> {:ok, %{intent: "status", order: "124"}} end},
          instructions: OrderDesk.Voice.instructions()
        )
      end,
      on_ready: &OrderDesk.Greeting.start/1,
      channel_options: OrderDesk.BrowserICE.channel_options()
    )
  end

  match _ do
    ParloraAcceptance.Server.call(conn, ParloraAcceptance.Server.init([]))
  end
end

Logger.configure(level: :warning)
{:ok, _} = Agent.start_link(fn -> 0 end, name: :fault_attempts)
{:ok, peer} = Bandit.start_link(plug: ParloraSilentSession.PeerRoute, ip: {127, 0, 0, 1}, port: 0)
{:ok, {_, peer_port}} = ThousandIsland.listener_info(peer)
Application.put_env(:order_desk, :fault_peer_port, peer_port)
Application.put_env(:order_desk, :greeting_progress_timeout_ms, 2_000)
port = System.fetch_env!("PORT") |> String.to_integer()
Application.put_env(:order_desk, :browser_origin, "http://127.0.0.1:#{port}")
Application.put_env(:order_desk, :browser_ice, OrderDesk.BrowserICE.load_env())

{:ok, _} =
  ParloraSilentSession.Collector.start_link(
    Path.join(System.fetch_env!("PILOT_OUTPUT"), "provider")
  )

{:ok, _} = ParloraAcceptance.Observer.start_link([])

:ok =
  :telemetry.attach("silent-fault", [:parlora, :event], &ParloraAcceptance.Observer.ready/4, nil)

{:ok, _} = Bandit.start_link(plug: ParloraSilentSession.Server, ip: {127, 0, 0, 1}, port: port)
IO.puts("FAULT_READY")
Process.sleep(:infinity)
