defmodule OrderDesk.BrowserGate do
  @moduledoc "Finite application-owned admission and session duration."
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def count, do: GenServer.call(__MODULE__, :count)
  def notify(actor, result), do: GenServer.cast(__MODULE__, {:saved, actor, result})

  def start_session(channel, actor \\ "offline", options \\ []),
    do: GenServer.call(__MODULE__, {:start, channel, self(), actor, options})

  @impl true
  def init(options) do
    {:ok,
     %{
       sessions: %{},
       max_sessions: Keyword.get(options, :max_sessions, 4),
       duration_ms: Keyword.get(options, :duration_ms, 180_000)
     }}
  end

  @impl true
  def handle_call(:count, _from, state), do: {:reply, map_size(state.sessions), state}

  def handle_call({:start, channel, owner, actor, options}, _from, state)
      when map_size(state.sessions) < state.max_sessions do
    provider =
      if Application.get_env(:order_desk, :browser_offline, false),
        do: {OrderDesk.ScriptedProvider, observer: owner},
        else: OrderDesk.Provider.selected()

    case OrderDesk.start_session(channel, provider,
           audio_format: Keyword.get(options, :audio_format, %Parlora.AudioFormat{}),
           event_sink: owner,
           context: %{actor: actor, customer: "demo"},
           context_policy:
             if(Application.get_env(:order_desk, :browser_offline, false),
               do: {OrderDesk.OrderPolicy, []},
               else: {OrderDesk.AppPolicy, []}
             ),
           instructions: OrderDesk.Voice.instructions()
         ) do
      {:ok, session} = reply ->
        if Process.whereis(OrderDesk.BrowserAudioDiagnostics),
          do: OrderDesk.BrowserAudioDiagnostics.attach(session, actor)

        {:ok, announcements} =
          Supervisor.start_child(
            OrderDesk.Supervisor,
            Supervisor.child_spec(
              {OrderDesk.SaveAnnouncements, session: session, provider: elem(provider, 0)},
              id: {OrderDesk.SaveAnnouncements, session},
              restart: :temporary
            )
          )

        ref = Process.monitor(session)
        timer = Process.send_after(self(), {:expire, session}, state.duration_ms)

        {:reply, reply,
         %{state | sessions: Map.put(state.sessions, ref, {session, timer, actor, announcements})}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:start, _channel, _owner, _actor, _options}, _from, state),
    do:
      {:reply, {:error, Parlora.Error.new(:backpressure, "Browser session limit reached")}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.sessions, ref) do
      {nil, _sessions} ->
        {:noreply, state}

      {{_session, timer, _actor, _announcements}, sessions} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | sessions: sessions}}
    end
  end

  def handle_info({:expire, session}, state) do
    if Enum.any?(state.sessions, fn {_ref, {pid, _timer, _actor, _announcements}} ->
         pid == session
       end),
       do: Parlora.close(session, :cancel)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:saved, actor, result}, state) do
    for {_ref, {_session, _timer, owner, announcements}} <- state.sessions, owner == actor do
      OrderDesk.SaveAnnouncements.saved(announcements, result)
    end

    {:noreply, state}
  end
end
