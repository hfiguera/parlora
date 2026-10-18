defmodule OrderDesk.GreetingTest do
  use ExUnit.Case, async: true
  alias Parlora.Event
  import ExUnit.CaptureLog

  defmodule Session do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:subscribe, subscriber}, _from, owner) do
      send(owner, {:subscriber, subscriber})
      {:reply, :ok, owner}
    end

    def handle_call({:expect_progress, id, timeout, options}, _from, owner) do
      send(owner, {:expected, id, timeout, options})
      {:reply, :ok, owner}
    end

    def handle_call({:resolve_progress, id, outcome}, _from, owner) do
      send(owner, {:resolved, id, outcome})
      {:reply, :ok, owner}
    end

    def handle_call({:append_context, context}, _from, owner) do
      send(owner, {:context, context})
      {:reply, :ok, owner}
    end
  end

  test "browser readiness starts the acknowledged greeting under supervision" do
    session = start_supervised!({Session, self()})
    assert {:ok, task} = OrderDesk.BrowserServer.greet(session)
    monitor = Process.monitor(task)
    assert_receive {:subscriber, ^task}, 1_000
    assert_receive {:context, %{id: id, kind: :instruction, content: content}}, 1_000
    assert_received {:expected, ^id, 30_000, [until: :conversation, on_timeout: :close]}
    assert content =~ "immediately without waiting"
    refute_receive {:context, _premature}, 30
    send(task, {:parlora_event, %Event{type: :context_acknowledged, command_id: id}})
    assert_receive {:context, %{kind: :speakable}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, 1_000
    refute_receive {:context, _extra}, 30
  end

  test "a submission without remote acknowledgment keeps the progress watch without a duplicate prompt" do
    session = start_supervised!({Session, self()})
    task = Task.async(fn -> OrderDesk.Greeting.run(session) end)
    assert_receive {:subscriber, subscriber}, 1_000
    assert_receive {:context, %{id: id}}, 1_000
    send(subscriber, {:parlora_event, %Event{type: :context_submitted, command_id: id}})
    Task.await(task)
    refute_receive {:context, _duplicate}, 30
    refute_received {:resolved, ^id, :completed}
  end

  test "missing acknowledgment is bounded and does not send commentary" do
    session = start_supervised!({Session, self()})

    assert capture_log(fn ->
             Task.async(fn -> OrderDesk.Greeting.run(session, timeout_ms: 30) end)
             |> Task.await()
           end) =~
             "Greeting acknowledgment timed out"

    assert_received {:context, %{kind: :instruction}}
    refute_received {:context, %{kind: :speakable}}
  end

  test "closing the session stops the greeting waiter" do
    session = start_supervised!({Session, self()})
    task = Task.async(fn -> OrderDesk.Greeting.run(session) end)
    assert_receive {:subscriber, _subscriber}, 1_000
    assert_receive {:context, %{kind: :instruction}}, 1_000
    GenServer.stop(session)
    assert Task.await(task, 1_000) == :ok
    refute_received {:context, %{kind: :speakable}}
  end

  test "opening commentary waits for the matching instruction acknowledgment" do
    session = start_supervised!({Session, self()})
    task = Task.async(fn -> OrderDesk.Greeting.run(session) end)
    assert_receive {:subscriber, subscriber}, 1_000
    assert_receive {:context, %{id: id, kind: :instruction}}, 1_000
    refute_receive {:context, _commentary}, 30
    send(subscriber, {:parlora_event, %Event{type: :context_acknowledged, command_id: "other"}})
    refute_receive {:context, _commentary}, 30
    send(subscriber, {:parlora_event, %Event{type: :context_acknowledged, command_id: id}})
    assert_receive {:context, %{kind: :speakable, content: content}}, 1_000
    assert content =~ "Begin the conversation"
    Task.await(task)
    refute_receive {:context, _duplicate}, 30
  end

  test "speech or rejection prevents an extra opening prompt" do
    for event <- [:transcript_delta, :context_rejected] do
      {:ok, session} = Session.start_link(self())
      task = Task.async(fn -> OrderDesk.Greeting.run(session) end)
      assert_receive {:subscriber, subscriber}, 1_000
      assert_receive {:context, %{id: id}}, 1_000
      send(subscriber, {:parlora_event, %Event{type: event, command_id: id}})
      send(subscriber, {:parlora_event, %Event{type: :context_acknowledged, command_id: id}})
      Task.await(task)
      refute_receive {:context, _extra}, 30
      GenServer.stop(session)
    end
  end
end
