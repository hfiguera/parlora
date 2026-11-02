defmodule BookingDesk.Conversation do
  @moduledoc "Bounded pending facts for one call; never proof of patient identity or consent."
  use GenServer, restart: :temporary

  @empty %{
    goal: nil,
    preferences: %{},
    identity: %{},
    registration_requested: false,
    registration_evidence: [],
    identity_changed: false,
    carrier: nil,
    phone: nil,
    phone_evidence: [],
    phone_previous_evidence: [],
    phone_cursor: nil,
    phone_turn: nil,
    reset_cursor: nil,
    declined_proposal: nil,
    reminder_route: :auto
  }
  @goals ~w(availability cancel reschedule)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def bind(pid, session), do: GenServer.call(pid, {:bind, session})

  def init(_),
    do: {:ok, %{frame: nil, session: nil, lookup_key: nil, verified_lookup: nil, data: @empty}}

  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  def context(snapshot),
    do: snapshot |> Map.get(:application_context, %{}) |> Map.get(:booking_conversation, @empty)

  def decision_context(snapshot),
    do:
      Map.drop(context(snapshot), [
        :identity,
        :registration_evidence,
        :phone_cursor,
        :phone_turn,
        :phone_previous_evidence
      ])

  def attach(snapshot, opts) do
    frame =
      {snapshot.session_id, snapshot.provider_generation, snapshot.revision, scope(snapshot),
       caller_cursor(snapshot)}

    data =
      case Keyword.get(opts, :conversation) do
        nil -> context(snapshot)
        pid -> GenServer.call(pid, {:read, frame, lookup_candidate(snapshot)})
      end

    put_context(snapshot, data, frame)
  end

  def remember(snapshot, opts, updates) do
    updates = Enum.map(updates, &with_cursor(&1, caller_cursor(snapshot)))
    frame = snapshot |> Map.get(:application_context, %{}) |> Map.get(:booking_conversation_frame)

    data =
      case Keyword.get(opts, :conversation) do
        nil -> update(context(snapshot), updates)
        pid -> GenServer.call(pid, {:remember, frame, updates})
      end

    put_context(snapshot, data, frame)
  end

  def preferences(judgment) do
    judgment
    |> Map.take(["intent", "date", "clinician", "time"])
    |> Enum.filter(fn
      {"intent", value} ->
        value in ~w(availability replace_search additional_search choose_slot reschedule)

      {"date", value} ->
        value in BookingDesk.Store.dates()

      {"clinician", value} ->
        value in ~w(lee patel any)

      {"time", value} ->
        value in ~w(10:15 14:00)
    end)
    |> Map.new()
  end

  def handle_call({:bind, session}, _, s) do
    Process.monitor(session)
    {:reply, :ok, %{s | session: session}}
  end

  def handle_call({:read, frame, candidate}, _, s) do
    s = advance(s, frame)
    s = if s.frame == frame, do: seed_lookup(s, candidate), else: s
    {:reply, if(s.frame == frame, do: s.data, else: @empty), s}
  end

  def handle_call({:remember, frame, updates}, _, %{frame: frame} = s) when frame != nil do
    data = if current_caller?(s), do: update(s.data, updates), else: s.data
    {:reply, data, %{s | data: data}}
  end

  def handle_call({:remember, _, _}, _, s), do: {:reply, @empty, s}
  def handle_info({:DOWN, _, :process, pid, _}, %{session: pid} = s), do: {:stop, :normal, s}

  defp advance(%{frame: nil} = s, frame), do: %{s | frame: frame}

  defp advance(
         %{frame: {session, gen, rev, old, _}} = s,
         {session, next_gen, next_rev, scope, _} = frame
       )
       when next_gen > gen or (next_gen == gen and next_rev >= rev) do
    %{s | frame: frame, data: scoped(s.data, old, scope)}
  end

  defp advance(s, _), do: s

  defp scoped(_, {old, _}, {new, _}) when old != nil and old != new, do: @empty

  defp scoped(data, {_, old}, {_, new}) when old != new,
    do: %{
      data
      | reminder_route: :auto,
        goal: nil,
        preferences: %{},
        declined_proposal: nil,
        phone: nil,
        phone_evidence: [],
        phone_previous_evidence: [],
        phone_cursor: nil,
        phone_turn: nil
    }

  defp scoped(data, _, _), do: data

  defp lookup_candidate(snapshot) do
    snapshot.tasks
    |> Map.values()
    |> Enum.filter(&(&1.input.operation == "lookup"))
    |> Enum.max_by(&Map.get(&1.input, :cursor, 0), fn -> nil end)
    |> case do
      %{input: %{name: name, dob: dob}, request_ids: [id | _]} -> {id, %{name: name, dob: dob}}
      _ -> nil
    end
  end

  defp seed_lookup(s, nil), do: s

  defp seed_lookup(s, {id, fields}) do
    data = if s.lookup_key != id, do: remember_identity(s.data, fields), else: s.data
    data = %{data | registration_requested: true}
    {_, _, _, {lookup, _}, _} = s.frame

    if lookup == id and Map.take(data.identity, [:name, :dob]) == fields and
         s.verified_lookup != lookup do
      %{
        s
        | lookup_key: id,
          verified_lookup: lookup,
          data: %{data | identity_changed: false, registration_evidence: []}
      }
    else
      %{s | lookup_key: id, data: data}
    end
  end

  defp booking(snapshot) do
    snapshot.tasks
    |> Map.values()
    |> Enum.filter(&(Map.get(&1.input, :operation) == "confirm" and &1.status == :completed))
    |> Enum.max_by(&Map.get(&1.input, :cursor, 0), fn -> nil end)
    |> case do
      %{request_ids: [id | _]} -> id
      _ -> nil
    end
  end

  defp update(data, updates) do
    Enum.reduce(updates, data, &put_fact/2)
  end

  defp scope(snapshot) do
    identity = BookingDesk.Policy.identity(snapshot)
    {identity && identity.lookup_request, booking(snapshot)}
  end

  defp caller_cursor(snapshot) do
    snapshot.transcripts
    |> Enum.filter(&(&1.speaker == :user))
    |> Enum.map(& &1.arrival_order)
    |> Enum.max(fn -> 0 end)
  end

  defp current_caller?(%{session: nil}), do: true

  defp current_caller?(%{session: session, frame: {id, gen, _, scope, cursor}}) do
    case Parlora.snapshot(session) do
      %Parlora.ContextSnapshot{} = current ->
        current.session_id == id and current.provider_generation == gen and
          caller_cursor(current) == cursor and scope(current) == scope

      _ ->
        false
    end
  catch
    :exit, _ -> false
  end

  defp with_cursor({:phone, {:incomplete, missing, fields}}, cursor),
    do:
      {:phone,
       {:incomplete, missing, fields |> Map.put(:cursor, cursor) |> Map.put_new(:turn, cursor)}}

  defp with_cursor({:phone, {:ok, fields}}, cursor),
    do: {:phone, {:ok, Map.put_new(fields, :turn, cursor)}}

  defp with_cursor(update, _), do: update

  defp put_fact({:judgment, {:ok, fields}}, data), do: remember_judgment(data, fields)

  defp put_fact({:reset, cursor}, %{reset_cursor: cursor} = data), do: data

  defp put_fact({:reset, cursor}, _),
    do: %{@empty | reset_cursor: cursor, identity_changed: true, registration_requested: true}

  defp put_fact({:search_declined, preferences}, data),
    do: %{data | preferences: preferences(preferences)}

  defp put_fact({:declined_proposal, id}, data),
    do: %{data | declined_proposal: id, goal: if(data.goal == "cancel", do: nil, else: data.goal)}

  defp put_fact({:reminder_route, route}, data) when route in [:active, :suspended],
    do: %{data | reminder_route: route}

  defp put_fact({:judgment, {:incomplete, fields, missing}}, data) do
    fields = if "intent" in missing, do: Map.delete(fields, "intent"), else: fields
    remember_judgment(data, fields)
  end

  defp put_fact({:identity, {:ok, fields}}, data), do: remember_identity(data, fields)
  defp put_fact({:identity, {:incomplete, _, fields}}, data), do: remember_identity(data, fields)

  defp put_fact({:identity, {:incomplete, [:ambiguous]}}, data),
    do: %{data | identity: %{}, identity_changed: true}

  defp put_fact({:registration_requested, true}, data), do: %{data | registration_requested: true}

  defp put_fact({:registration_text, text}, data) when is_binary(text) do
    previous = data.registration_evidence

    parts =
      case previous do
        [last | rest] ->
          if String.starts_with?(text, last), do: [text | rest], else: [text | previous]

        [] ->
          [text]
      end

    if length(parts) <= 32 and Enum.reduce(parts, 0, &(byte_size(&1) + &2)) <= 4_096,
      do: %{data | registration_evidence: parts},
      else: data
  end

  defp put_fact({:carrier, {:ok, %{carrier: carrier}}}, data), do: remember_carrier(data, carrier)

  defp put_fact({:phone, {:ok, %{phone: phone, turn: turn}}}, data),
    do: remember_phone(data, phone, turn)

  defp put_fact({:phone, {:incomplete, _, %{cursor: cursor}}}, %{phone_cursor: cursor} = data),
    do: data

  defp put_fact({:phone, {:incomplete, _, %{evidence: parts, cursor: cursor, turn: turn}}}, data) do
    previous = previous_phone_evidence(data, turn)
    parts = Enum.filter(previous ++ parts, &(is_binary(&1) and byte_size(&1) <= 256))

    %{
      data
      | phone: nil,
        phone_cursor: cursor,
        phone_turn: turn,
        phone_previous_evidence: previous,
        phone_evidence: recent_evidence(parts)
    }
  end

  defp put_fact({:phone, :clear}, data),
    do: %{
      data
      | phone: nil,
        phone_evidence: [],
        phone_previous_evidence: [],
        phone_cursor: nil,
        phone_turn: nil
    }

  defp put_fact(_, data), do: data

  defp remember_judgment(data, fields) do
    intent = fields["intent"]
    goal = next_goal(data, intent)
    carrier = if intent == "insurance_changed", do: nil, else: data.carrier
    fields = if intent in ~w(confirm progress none), do: %{}, else: preferences(fields)

    %{
      data
      | goal: goal,
        registration_requested: data.registration_requested or intent == "lookup",
        identity_changed: data.identity_changed or intent == "lookup",
        carrier: carrier,
        preferences: Map.merge(data.preferences, Map.delete(fields, "intent"))
    }
  end

  defp next_goal(data, intent) when intent in ~w(replace_search additional_search choose_slot),
    do: data.goal || intent

  defp next_goal(_, intent) when intent in @goals, do: intent
  defp next_goal(data, _), do: data.goal

  defp remember_identity(data, fields) do
    fields = Map.take(fields, [:name, :dob, :name_evidence, :dob_evidence])
    fields = if :erlang.external_size(fields) <= 2_048, do: fields, else: %{}

    changed =
      changed_field?(data.identity, fields, :name) or changed_field?(data.identity, fields, :dob)

    data =
      if changed, do: %{@empty | registration_requested: true, identity_changed: true}, else: data

    identity = merge_identity(data.identity, fields)
    %{data | identity: identity}
  end

  defp changed_field?(previous, fields, key),
    do: previous[key] != nil and fields[key] != nil and previous[key] != fields[key]

  defp merge_identity(previous, %{dob_evidence: parts} = fields)
       when not is_map_key(fields, :dob) do
    parts = recent_evidence(Enum.uniq(Map.get(previous, :dob_evidence, []) ++ parts))
    previous |> Map.delete(:dob) |> Map.merge(Map.put(fields, :dob_evidence, parts))
  end

  defp merge_identity(previous, fields), do: Map.merge(previous, fields)

  defp recent_evidence(parts), do: parts |> Enum.reverse() |> Enum.take(4) |> Enum.reverse()

  defp previous_phone_evidence(%{phone_turn: turn} = data, turn), do: data.phone_previous_evidence
  defp previous_phone_evidence(%{phone: phone}, _) when is_binary(phone), do: [phone]
  defp previous_phone_evidence(data, _), do: data.phone_evidence

  defp remember_carrier(data, carrier) do
    if BookingDesk.Insurance.valid_carrier?(carrier), do: %{data | carrier: carrier}, else: data
  end

  defp remember_phone(data, phone, turn) do
    if BookingDesk.Reminders.phone(phone) == phone and phone != nil,
      do: %{
        data
        | phone: phone,
          phone_evidence: [],
          phone_previous_evidence: [],
          phone_cursor: nil,
          phone_turn: turn
      },
      else: data
  end

  defp put_context(snapshot, data, frame) do
    context =
      Map.merge(Map.get(snapshot, :application_context, %{}), %{
        booking_conversation: data,
        booking_conversation_frame: frame
      })

    Map.put(snapshot, :application_context, context)
  end
end
