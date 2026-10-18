# Diagnostic observer: private BrowserGate state is used only to discover sessions.
# Never dump session/provider state, headers, credentials, transcripts or PCM.
Task.start_link(fn ->
  observe = fn observe, known ->
    sessions = :sys.get_state(OrderDesk.BrowserGate).sessions
    pids = for {_ref, {pid, _timer, _actor, _announcements}} <- sessions, do: pid
    for pid <- pids, not MapSet.member?(known, pid), do: Parlora.subscribe(pid)

    receive do
      {:parlora_event, %Parlora.Event{type: type, command_id: id}}
      when type in [:ready, :context_acknowledged, :context_rejected, :transcript_delta, :closed] ->
        IO.puts("STARTUP_OBSERVATION " <> Jason.encode!(%{type: type, command_id: id}))
      _other -> :ok
    after
      10 -> :ok
    end

    observe.(observe, MapSet.new(pids))
  end

  observe.(observe, MapSet.new())
end)
Code.require_file("../browser-gap-20260921/trace_server.exs", __DIR__)
