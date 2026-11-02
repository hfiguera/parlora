defmodule BookingDesk.ConversationTest.Session do
  use GenServer
  def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
  def init(snapshot), do: {:ok, snapshot}
  def handle_call(:snapshot, _, snapshot), do: {:reply, snapshot, snapshot}
end

defmodule BookingDesk.ConversationTest do
  use ExUnit.Case, async: false
  alias BookingDesk.{Conversation, Store}
  alias Parlora.ContextSnapshot

  defp snapshot(revision \\ 1),
    do: %ContextSnapshot{session_id: "memory-test", provider_generation: 0, revision: revision}

  test "facts and the scheduling goal survive many uncertain turns and registration steps" do
    memory = start_supervised!(Conversation)
    opts = [conversation: memory]
    first = Conversation.attach(snapshot(), opts)

    Conversation.remember(first, opts,
      judgment:
        {:ok,
         %{
           "intent" => "reschedule",
           "date" => "2026-11-05",
           "clinician" => "lee",
           "time" => "10:15"
         }},
      identity: {:incomplete, [:dob], %{name: "jamie rivera", name_evidence: "Jamie Rivera"}},
      carrier: {:ok, %{carrier: "Cigna"}},
      phone: {:ok, %{phone: "+12025550199"}}
    )

    for revision <- 2..200 do
      current = Conversation.attach(snapshot(revision), opts)
      Conversation.remember(current, opts, judgment: {:error, :uncertain})
      data = Conversation.context(current)
      assert data.goal == "reschedule"
      assert data.preferences["date"] == "2026-11-05"
      assert data.identity.name == "jamie rivera"
      assert data.carrier == "Cigna"
      assert data.phone == "+12025550199"
      assert :erlang.external_size(data) < 4_096
    end

    current = Conversation.attach(snapshot(201), opts)

    for intent <-
          ~w(lookup insurance_same progress none confirm replace_search additional_search choose_slot) do
      Conversation.remember(current, opts, judgment: {:ok, %{"intent" => intent}})
    end

    assert Conversation.context(Conversation.attach(snapshot(202), opts)).goal == "reschedule"
    refute inspect(:sys.get_status(memory)) =~ "jamie rivera"
  end

  test "patient changes clear pending facts and stale work cannot restore them" do
    session = "memory-scope"

    for {id, name, dob} <- [
          {"old-memory-lookup", "Jamie Rivera", "1990-03-12"},
          {"new-memory-lookup", "Alex Morgan", "1985-07-24"}
        ] do
      Store.execute(%{operation: "lookup", name: name, dob: dob, session: session}, id)
    end

    memory = start_supervised!(Conversation)
    opts = [conversation: memory]

    initial = %{
      snapshot()
      | session_id: session,
        application_context: %{lookup_request: "old-memory-lookup"}
    }

    initial = Conversation.attach(initial, opts)

    Conversation.remember(initial, opts,
      carrier: {:ok, %{carrier: "Cigna"}},
      phone: {:ok, %{phone: "+12025550199"}}
    )

    changed = %{
      initial
      | revision: 2,
        application_context: %{lookup_request: "new-memory-lookup"}
    }

    assert Conversation.context(Conversation.attach(changed, opts)).phone == nil
    Conversation.remember(initial, opts, phone: {:ok, %{phone: "+12025550199"}})
    assert Conversation.context(Conversation.attach(changed, opts)).carrier == nil

    newer = %{changed | provider_generation: 1, revision: 3}
    newer = Conversation.attach(newer, opts)
    Conversation.remember(newer, opts, carrier: {:ok, %{carrier: "Aetna"}})
    Conversation.remember(changed, opts, carrier: {:ok, %{carrier: "Cigna"}})
    assert Conversation.context(Conversation.attach(newer, opts)).carrier == "Aetna"
    assert Conversation.context(Conversation.attach(initial, opts)).carrier == nil
  end

  test "progress and social replies cannot overwrite retained scheduling preferences" do
    memory = start_supervised!(Conversation)
    opts = [conversation: memory]
    current = Conversation.attach(snapshot(), opts)

    Conversation.remember(current, opts,
      judgment:
        {:incomplete, %{"date" => "2026-11-05", "clinician" => "patel", "time" => "14:00"},
         ["intent"]}
    )

    for intent <- ~w(progress none) do
      Conversation.remember(current, opts,
        judgment:
          {:ok,
           %{"intent" => intent, "date" => "2026-11-04", "clinician" => "lee", "time" => "10:15"}}
      )

      retained = Conversation.context(Conversation.attach(snapshot(), opts)).preferences
      assert retained == %{"date" => "2026-11-05", "clinician" => "patel", "time" => "14:00"}
    end
  end

  test "a new identity invalidates old details and a closed call releases its memory" do
    memory = start_supervised!(Conversation)
    opts = [conversation: memory]
    s = Conversation.attach(snapshot(), opts)

    Conversation.remember(s, opts,
      identity: {:ok, %{name: "jamie rivera", dob: "1990-03-12"}},
      phone: {:ok, %{phone: "+12025550199"}}
    )

    s = Conversation.attach(snapshot(2), opts)

    s =
      Conversation.remember(s, opts,
        identity: {:incomplete, [:dob], %{name: "alex morgan", name_evidence: "Alex Morgan"}}
      )

    assert Conversation.context(s).identity_changed
    refute Map.has_key?(Conversation.context(s).identity, :dob)
    assert Conversation.context(s).phone == nil
    assert BookingDesk.Policy.identity(s) == nil

    session =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = Conversation.bind(memory, session)
    ref = Process.monitor(memory)
    send(session, :stop)
    assert_receive {:DOWN, ^ref, :process, ^memory, :normal}
  end

  test "a newer caller revision invalidates an in-flight result before another memory read" do
    first = %{snapshot() | transcripts: [%{speaker: :user, delta: "Wednesday", arrival_order: 1}]}
    session = start_supervised!({__MODULE__.Session, first})
    memory = start_supervised!(Conversation)
    opts = [conversation: memory]
    Conversation.bind(memory, session)
    old = Conversation.attach(first, opts)

    new = %{
      first
      | revision: 2,
        transcripts: [%{speaker: :user, delta: "Thursday instead", arrival_order: 2}]
    }

    :sys.replace_state(session, fn _ -> new end)

    Conversation.remember(old, opts,
      judgment: {:ok, %{"intent" => "availability", "date" => "2026-11-04"}}
    )

    new = Conversation.attach(new, opts)
    assert Conversation.context(new).preferences == %{}

    new =
      Conversation.remember(new, opts,
        judgment: {:ok, %{"intent" => "replace_search", "date" => "2026-11-05"}}
      )

    assert Conversation.context(new).preferences["date"] == "2026-11-05"
  end

  test "phone fragments retain repeated digits across turns without duplicating polls" do
    memory = start_supervised!(Conversation)
    opts = [conversation: memory]
    first = %{snapshot() | transcripts: [%{speaker: :user, delta: "five five", arrival_order: 1}]}
    first = Conversation.attach(first, opts)
    partial = {:incomplete, [:phone], %{evidence: ["five five"]}}
    for _ <- 1..10, do: Conversation.remember(first, opts, phone: partial)
    first = Conversation.attach(first, opts)
    assert Conversation.context(first).phone_evidence == ["five five"]

    next = %{
      first
      | revision: 2,
        transcripts: [%{speaker: :user, delta: "five five", arrival_order: 2}]
    }

    next = Conversation.attach(next, opts)
    next = Conversation.remember(next, opts, phone: partial)
    assert Conversation.context(next).phone_evidence == ["five five", "five five"]
    assert Conversation.context(next).phone == nil
  end

  test "a DOB correction cannot reuse the selected record even when the name is unchanged" do
    id = "dob-correction-lookup"
    session = "dob-correction"

    input = %{
      operation: "lookup",
      name: "jamie rivera",
      dob: "1990-03-12",
      session: session,
      cursor: 1
    }

    Store.execute(input, id)

    s = %{
      snapshot()
      | session_id: session,
        application_context: %{lookup_request: id},
        tasks: %{
          "lookup" => %{
            id: "lookup",
            revision: 1,
            status: :completed,
            input: input,
            request_ids: [id]
          }
        }
    }

    memory = start_supervised!(Conversation)
    opts = [conversation: memory]
    current = Conversation.attach(s, opts)

    Conversation.remember(current, opts, judgment: {:ok, %{"intent" => "lookup"}})
    assert Conversation.context(Conversation.attach(s, opts)).identity_changed

    Conversation.remember(current, opts,
      identity: {:ok, %{name: "jamie rivera", dob: "1991-03-12"}}
    )

    current = Conversation.attach(%{s | revision: 2}, opts)
    assert Conversation.context(current).identity_changed
    assert Conversation.context(current).identity.dob == "1991-03-12"
    assert BookingDesk.Policy.identity(current) == nil

    fresh_id = "dob-correction-verified"
    Store.execute(input, fresh_id)

    fresh = %{
      s
      | revision: 3,
        application_context: %{lookup_request: fresh_id},
        tasks: put_in(s.tasks, ["lookup", :request_ids], [fresh_id])
    }

    fresh = Conversation.attach(fresh, opts)
    refute Conversation.context(fresh).identity_changed
    assert BookingDesk.Policy.identity(fresh).lookup_request == fresh_id
  end
end
