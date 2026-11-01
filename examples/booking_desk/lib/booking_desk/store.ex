defmodule BookingDesk.Store do
  @moduledoc "Fictional scheduling records. Immutable proposals and transactional, idempotent writes."
  use GenServer
  alias Exqlite.Sqlite3, as: SQL
  @dates ~w(2026-11-04 2026-11-05 2026-11-06 2026-11-11 2026-11-12)
  def dates, do: @dates
  def clinicians, do: %{"lee" => "Dr. Lee", "patel" => "Dr. Patel"}
  def slot_id(date, time, "lee"), do: date <> "T" <> time <> ":00"
  def slot_id(date, time, "patel"), do: date <> "T" <> time <> ":00@patel"

  def identity(request, session, server \\ __MODULE__),
    do: GenServer.call(server, {:identity, request, session})

  def insurance(request, session, server \\ __MODULE__),
    do: GenServer.call(server, {:insurance, request, session})

  def reminder(booking, lookup, session, server \\ __MODULE__),
    do: GenServer.call(server, {:reminder, booking, lookup, session})

  def reminder_jobs(server \\ __MODULE__), do: GenServer.call(server, :reminder_jobs)

  def offered(patient, cursor, lookup, server \\ __MODULE__),
    do: GenServer.call(server, {:offered, patient, cursor, lookup})

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def execute(input, id, server \\ __MODULE__), do: GenServer.call(server, {:execute, input, id})
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  def proposals(server \\ __MODULE__), do: GenServer.call(server, :proposals)

  def readback_proposal(patient, id, revision, server \\ __MODULE__),
    do: GenServer.call(server, {:readback_proposal, patient, id, revision})

  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    if path != ":memory:", do: File.mkdir_p!(Path.dirname(path))
    {:ok, db} = SQL.open(path)
    if path != ":memory:", do: File.chmod!(path, 0o600)

    :ok =
      SQL.execute(db, """
      PRAGMA foreign_keys=ON;
      PRAGMA busy_timeout=1000;
      CREATE TABLE IF NOT EXISTS patients(id TEXT PRIMARY KEY, name TEXT, phone TEXT UNIQUE);
      CREATE TABLE IF NOT EXISTS slots(id TEXT PRIMARY KEY, date TEXT, provider TEXT);
      CREATE TABLE IF NOT EXISTS appointments(id TEXT PRIMARY KEY, patient TEXT REFERENCES patients(id), slot TEXT REFERENCES slots(id), status TEXT, confirmation TEXT UNIQUE);
      CREATE UNIQUE INDEX IF NOT EXISTS active_slot ON appointments(slot) WHERE status='booked';
      CREATE TABLE IF NOT EXISTS proposals(id TEXT PRIMARY KEY, patient TEXT, operation TEXT, slot TEXT, appointment TEXT, revision INTEGER, status TEXT, expires INTEGER);
      CREATE TABLE IF NOT EXISTS offers(patient TEXT, slot TEXT, cursor INTEGER, expires INTEGER, PRIMARY KEY(patient,slot,cursor));
      CREATE TABLE IF NOT EXISTS verified_offers(patient TEXT, slot TEXT, cursor INTEGER, expires INTEGER, lookup_request TEXT, PRIMARY KEY(lookup_request,slot,cursor));
      CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY, input TEXT, result TEXT);
      CREATE TABLE IF NOT EXISTS insurance_reviews(lookup_request TEXT PRIMARY KEY,session TEXT,patient TEXT,carrier TEXT,revision INTEGER,status TEXT,request_id TEXT UNIQUE);
      INSERT OR IGNORE INTO patients(id,name,phone) VALUES('p_1002','Jamie Rivera','2025550188');
      INSERT OR IGNORE INTO patients(id,name,phone) VALUES('p_1003','Alex Morgan','6175559210');
      """)

    unless Enum.any?(query(db, "PRAGMA table_info(patients)", []), &(Enum.at(&1, 1) == "dob")),
      do: SQL.execute(db, "ALTER TABLE patients ADD COLUMN dob TEXT")

    query(db, "UPDATE patients SET dob='1990-03-12' WHERE id='p_1002' AND dob IS NULL", [])
    query(db, "UPDATE patients SET dob='1985-07-24' WHERE id='p_1003' AND dob IS NULL", [])

    for {column, type} <- [
          {"insurance_carrier", "TEXT"},
          {"insurance_revision", "INTEGER DEFAULT 1"},
          {"insurance_needs_update", "INTEGER DEFAULT 0"}
        ] do
      unless Enum.any?(query(db, "PRAGMA table_info(patients)", []), &(Enum.at(&1, 1) == column)),
        do: SQL.execute(db, "ALTER TABLE patients ADD COLUMN #{column} #{type}")
    end

    query(
      db,
      "UPDATE patients SET insurance_carrier='Aetna' WHERE id='p_1002' AND insurance_carrier IS NULL",
      []
    )

    query(
      db,
      "UPDATE patients SET insurance_carrier='Cigna' WHERE id='p_1003' AND insurance_carrier IS NULL",
      []
    )

    unless Enum.any?(
             query(db, "PRAGMA table_info(proposals)", []),
             &(Enum.at(&1, 1) == "lookup_request")
           ),
           do: SQL.execute(db, "ALTER TABLE proposals ADD COLUMN lookup_request TEXT")

    for date <- @dates -- ["2026-11-06", "2026-11-11"],
        time <- ["10:15", "14:00"],
        {clinician, name} <- clinicians() do
      query(db, "INSERT OR IGNORE INTO slots VALUES(?,?,?)", [
        slot_id(date, time, clinician),
        date,
        name
      ])
    end

    query(db, "INSERT OR IGNORE INTO slots VALUES(?,?,?)", [
      "2026-11-03T09:00:00",
      "2026-11-03",
      "Dr. Patel"
    ])

    query(
      db,
      "INSERT OR IGNORE INTO appointments VALUES('appt_existing','p_1002','2026-11-03T09:00:00','booked','BD-EXISTING')",
      []
    )

    :ok = BookingDesk.Reminders.init(db)
    {:ok, db}
  end

  def handle_call({:reminder, booking, lookup, session}, _from, db),
    do: {:reply, BookingDesk.Reminders.state(db, booking, lookup, session), db}

  def handle_call(:reminder_jobs, _from, db), do: {:reply, BookingDesk.Reminders.jobs(db), db}

  def handle_call({:identity, request, session}, _from, db),
    do: {:reply, matched_identity(db, request, session), db}

  def handle_call({:insurance, request, session}, _from, db),
    do: {:reply, insurance_state(db, request, session), db}

  def handle_call({:offered, patient, cursor, lookup}, _from, db) do
    slots =
      query(
        db,
        "SELECT s.id,s.date,s.provider FROM verified_offers o JOIN slots s ON s.id=o.slot WHERE o.patient=? AND o.cursor=? AND o.lookup_request=? AND o.expires>? ORDER BY s.id",
        [patient, cursor, lookup, System.system_time(:second)]
      )

    {:reply, Enum.map(slots, &slot_fact/1), db}
  end

  def handle_call(:snapshot, _from, db) do
    appointments =
      query(db, "SELECT id,patient,slot,status,confirmation FROM appointments ORDER BY id", [])

    {:reply, appointments, db}
  end

  def handle_call(:proposals, _from, db),
    do:
      {:reply,
       query(
         db,
         "SELECT id,patient,operation,slot,appointment,revision,status FROM proposals ORDER BY rowid",
         []
       ), db}

  def handle_call({:readback_proposal, patient, id, revision}, _from, db) do
    result =
      query(
        db,
        """
        SELECT p.slot,s.provider,p.expires,p.lookup_request FROM proposals p JOIN slots s ON s.id=p.slot
        WHERE p.id=? AND p.patient=? AND p.revision=? AND p.status='pending'
          AND p.operation='book' AND p.expires>?
        """,
        [id, patient, revision, System.system_time(:second)]
      )

    proposal =
      case result do
        [[slot, clinician, expires, lookup]] ->
          %{
            id: id,
            patient: patient,
            lookup_request: lookup,
            revision: revision,
            slot: slot,
            clinician: clinician,
            clinician_id:
              Enum.find_value(clinicians(), fn {key, name} -> if name == clinician, do: key end),
            expires: expires,
            status: "pending",
            change: "book"
          }

        _ ->
          nil
      end

    {:reply, if(proposal_insurance?(db, id), do: proposal), db}
  end

  def handle_call({:execute, input, id}, _from, db) do
    encoded = JSON.encode!(input)

    result =
      case query(db, "SELECT input,result FROM receipts WHERE id=?", [id]) do
        [[^encoded, result]] ->
          JSON.decode!(result)

        [[_, _]] ->
          failure("Conflicting request identifier. No new action was taken.")

        [] ->
          :ok = SQL.execute(db, "BEGIN IMMEDIATE")
          result = perform(db, input, id)
          query(db, "INSERT INTO receipts VALUES(?,?,?)", [id, encoded, JSON.encode!(result)])
          :ok = SQL.execute(db, "COMMIT")
          result
      end

    {:reply, JSON.decode!(JSON.encode!(result)), db}
  end

  defp perform(db, %{operation: "lookup", name: name, dob: dob, session: session}, _id)
       when is_binary(name) and is_binary(dob) and is_binary(session) do
    case query(db, "SELECT id FROM patients WHERE lower(trim(name))=? AND dob=?", [
           String.downcase(String.trim(name)),
           dob
         ]) do
      [[patient]] ->
        insurance = patient_insurance(db, patient)
        question = BookingDesk.Insurance.question(insurance)

        success(
          "The caller's fictional patient record matched. Ask: #{question} Wait for their answer before searching appointments. These are stored insurance details, not verified eligibility. Do not repeat the supplied name, DOB, date or doctor.",
          %{patient: patient, insurance: insurance}
        )

      _ ->
        failure(
          "No unique matching fictional patient record. Ask the caller to check the full name and date of birth; no appointment was changed."
        )
    end
  end

  defp perform(db, %{patient: patient, lookup_request: lookup, session: session} = input, id) do
    cond do
      not is_binary(patient) or matched_identity(db, lookup, session) != patient ->
        failure(
          "Match the caller's full name and date of birth before scheduling. No change was made."
        )

      input.operation in ~w(reminder_opt_in reminder_decline reminder_change reminder_number reminder_confirm) ->
        BookingDesk.Reminders.execute(db, input, id)

      input.operation == "insurance" ->
        perform_verified(db, input, id)

      not reviewed_insurance?(db, input) ->
        failure(
          "Confirm or update the insurance information on file before scheduling. No appointment was changed."
        )

      true ->
        perform_verified(db, input, id)
    end
  end

  defp perform(_db, _input, _id),
    do: failure("A matching patient lookup is required before scheduling. No change was made.")

  defp perform_verified(
         db,
         %{
           operation: "insurance",
           response: response,
           insurance_revision: revision,
           carrier: carrier
         } = input,
         id
       )
       when response in ["unchanged", "changed", "updated"] do
    current = patient_insurance(db, input.patient)

    cond do
      current.revision != revision ->
        failure(
          "The insurance information changed since it was read. Ask about the current information again."
        )

      response == "unchanged" and (current.carrier != carrier or current.needs_update) ->
        failure(
          "The supplied insurer is not the current information on file. Ask which insurance they have now."
        )

      response == "updated" and not BookingDesk.Insurance.valid_carrier?(carrier) ->
        failure("Ask for the insurance company or plan name. No insurance details were changed.")

      true ->
        save_insurance_review(db, input, id, current)
    end
  end

  defp perform_verified(
         db,
         %{operation: "availability", date: date, clinician: clinician} = input,
         _id
       )
       when date in @dates and clinician in ["lee", "patel", "any"] do
    if date == "2026-11-11" do
      failure(
        "The availability service failed. No availability has been verified; ask whether to try again."
      )
    else
      clinician = Map.get(input, :clinician)
      names = if clinician == "any", do: Map.values(clinicians()), else: [clinicians()[clinician]]

      slots =
        query(
          db,
          "SELECT s.id,s.date,s.provider FROM slots s WHERE date=? AND NOT EXISTS(SELECT 1 FROM appointments a WHERE a.slot=s.id AND a.status='booked') ORDER BY s.id",
          [date]
        )
        |> Enum.filter(fn [_, _, provider] -> provider in names end)
        |> Enum.map(&slot_fact/1)

      for slot <- slots do
        query(db, "INSERT OR REPLACE INTO verified_offers VALUES(?,?,?,?,?)", [
          input.patient,
          slot.id,
          Map.get(input, :cursor, 0),
          System.system_time(:second) + 300,
          input.lookup_request
        ])
      end

      summary = availability_summary(date, slots)

      success(summary, %{date: date, clinician: clinician, slots: slots})
    end
  end

  defp perform_verified(
         db,
         %{operation: "propose", patient: patient, slot: slot, revision: _revision} = input,
         id
       ) do
    operation = Map.get(input, :change, "book")
    appointment = Map.get(input, :appointment, "")
    valid_patient = query(db, "SELECT id FROM patients WHERE id=?", [patient]) != []

    owned =
      query(db, "SELECT id FROM appointments WHERE id=? AND patient=? AND status='booked'", [
        appointment,
        patient
      ]) != []

    clinician_name = slot_clinician_name(db, slot)

    slot_exists = clinician_name != nil

    clinician =
      clinician_id(clinician_name)

    offered =
      query(
        db,
        "SELECT slot FROM verified_offers WHERE patient=? AND slot=? AND cursor=? AND lookup_request=? AND expires>?",
        [
          patient,
          slot,
          Map.get(input, :search_cursor, -1),
          input.lookup_request,
          System.system_time(:second)
        ]
      ) != []

    cond do
      not valid_patient ->
        failure("Unknown caller record.")

      operation not in ["book", "cancel", "reschedule"] ->
        failure("Unsupported scheduling change.")

      operation in ["cancel", "reschedule"] and not owned ->
        failure(
          "That appointment does not belong to this fictional caller or is no longer active."
        )

      operation != "cancel" and
          not verified_slot?(slot_exists, offered, input, clinician) ->
        failure("That slot is not in the verified calendar.")

      true ->
        save_proposal(db, input, id, operation, appointment, clinician, clinician_name)
    end
  end

  defp perform_verified(
         db,
         %{
           operation: "confirm",
           patient: patient,
           proposal: proposal,
           revision: revision,
           lookup_request: lookup
         },
         id
       ) do
    case query(
           db,
           "SELECT operation,slot,appointment,status,expires FROM proposals WHERE id=? AND patient=? AND revision=? AND lookup_request=?",
           [proposal, patient, revision, lookup]
         ) do
      [[operation, slot, appointment, "pending", expires]] ->
        cond do
          not proposal_insurance?(db, proposal) ->
            failure(
              "The insurance information changed after this proposal. Please choose and confirm the appointment again."
            )

          expires <= System.system_time(:second) ->
            failure("That proposal expired. Please choose and confirm a slot again.")

          String.starts_with?(slot, "2026-11-12") ->
            failure("Booking service failed. No appointment was booked or cancelled.")

          true ->
            apply_change(db, patient, proposal, operation, slot, appointment, id)
        end

      _ ->
        failure("No current matching proposal. Please choose and confirm the exact change again.")
    end
  end

  defp perform_verified(_db, _input, _id),
    do: failure("Missing or invalid scheduling details. No change was made.")

  defp apply_change(db, patient, proposal, "cancel", _slot, appointment, id) do
    if query(db, "SELECT id FROM appointments WHERE id=? AND patient=? AND status='booked'", [
         appointment,
         patient
       ]) == [] do
      failure("That appointment is no longer active. No change was made.")
    else
      query(db, "UPDATE appointments SET status='cancelled' WHERE id=? AND patient=?", [
        appointment,
        patient
      ])

      BookingDesk.Reminders.cancel(db, appointment)
      query(db, "UPDATE proposals SET status='applied' WHERE id=?", [proposal])

      success("Appointment cancelled. Cancellation confirmation BD-#{id}.", %{
        cancelled: appointment
      })
    end
  end

  defp apply_change(db, patient, proposal, operation, slot, appointment, id) do
    occupied =
      query(db, "SELECT id FROM appointments WHERE slot=? AND status='booked'", [slot]) != []

    owned =
      query(db, "SELECT id FROM appointments WHERE id=? AND patient=? AND status='booked'", [
        appointment,
        patient
      ]) != []

    cond do
      occupied ->
        failure(
          "That slot was taken. Nothing was booked or cancelled. Please check another slot."
        )

      operation == "reschedule" and not owned ->
        failure("The original appointment changed. Nothing was booked or cancelled.")

      true ->
        confirmation =
          "BD-" <> (:crypto.hash(:sha256, id) |> binary_part(0, 4) |> Base.encode16())

        query(db, "INSERT INTO appointments VALUES(?,?,?,'booked',?)", [
          id,
          patient,
          slot,
          confirmation
        ])

        if operation == "reschedule",
          do:
            query(db, "UPDATE appointments SET status='cancelled' WHERE id=? AND patient=?", [
              appointment,
              patient
            ])

        if operation == "reschedule", do: BookingDesk.Reminders.cancel(db, appointment)
        query(db, "UPDATE proposals SET status='applied' WHERE id=?", [proposal])

        [[clinician_name]] = query(db, "SELECT provider FROM slots WHERE id=?", [slot])

        clinician =
          clinician_id(clinician_name)

        success(
          "#{if operation == "reschedule", do: "Rescheduled", else: "Booked"}: #{slot_label(slot)}, #{clinician_name}. Confirmation #{confirmation}. Ask whether they would like a text reminder 24 hours before the appointment. Wait for their answer; do not assume consent or a mobile number.",
          %{
            appointment: id,
            slot: slot,
            confirmation: confirmation,
            patient: patient,
            clinician: clinician,
            clinician_name: clinician_name
          }
        )
    end
  end

  defp save_insurance_review(
         db,
         %{response: response, insurance_revision: revision, carrier: carrier} = input,
         id,
         current
       ) do
    changed = response in ["changed", "updated"]
    next_revision = revision + if(changed, do: 1, else: 0)
    next_carrier = if response == "updated", do: carrier, else: current.carrier
    needs_update = response == "changed"

    if changed do
      query(
        db,
        "UPDATE patients SET insurance_carrier=?,insurance_revision=?,insurance_needs_update=? WHERE id=?",
        [next_carrier, next_revision, if(needs_update, do: 1, else: 0), input.patient]
      )
    end

    query(db, "INSERT OR REPLACE INTO insurance_reviews VALUES(?,?,?,?,?,?,?)", [
      input.lookup_request,
      input.session,
      input.patient,
      next_carrier,
      next_revision,
      if(needs_update, do: "needs_update", else: "confirmed"),
      id
    ])

    insurance = %{
      carrier: next_carrier,
      revision: next_revision,
      needs_update: needs_update,
      confirmed: not needs_update,
      insurance_request: if(needs_update, do: nil, else: id)
    }

    summary =
      if needs_update,
        do:
          "The caller says their insurance changed. Ask which insurance company or plan they have now. Wait before searching appointments.",
        else:
          "The caller confirmed their insurance information on file. Continue with their requested appointment; do not ask about insurance again. This does not verify eligibility, network participation or coverage."

    success(summary, %{
      patient: input.patient,
      insurance: insurance,
      eligibility_verified: false
    })
  end

  defp availability_summary(date, slots) do
    if slots == [] do
      "There are no appointments available for the requested clinician preference on #{date_label(date)}."
    else
      options =
        slots
        |> Enum.group_by(& &1.clinician_name)
        |> Enum.sort()
        |> Enum.map_join("; ", fn {name, items} ->
          "#{name} has #{Enum.map_join(items, " or ", &time_label(&1.id))}"
        end)

      "Verified availability for #{date_label(date)}: #{options}. Offer the actual returned doctors and times and ask which the caller prefers. No booking has been made."
    end
  end

  defp slot_clinician_name(db, slot) do
    case query(db, "SELECT provider FROM slots WHERE id=?", [slot]) do
      [[name]] -> name
      _ -> nil
    end
  end

  defp clinician_id(name) do
    Enum.find_value(clinicians(), fn
      {key, ^name} -> key
      _ -> nil
    end)
  end

  defp save_proposal(
         db,
         %{patient: patient, slot: slot, revision: revision} = input,
         id,
         operation,
         appointment,
         clinician,
         clinician_name
       ) do
    query(
      db,
      "UPDATE proposals SET status='superseded' WHERE patient=? AND status='pending'",
      [patient]
    )

    query(
      db,
      "INSERT INTO proposals(id,patient,operation,slot,appointment,revision,status,expires,lookup_request) VALUES(?,?,?,?,?,?,'pending',?,?)",
      [
        id,
        patient,
        operation,
        slot,
        appointment,
        revision,
        System.system_time(:second) + 300,
        input.lookup_request
      ]
    )

    description =
      case operation do
        "cancel" ->
          "cancel the existing appointment on Tuesday November 3 at 9 AM with Dr. Patel"

        "reschedule" ->
          "move the existing November 3 appointment to #{slot_label(slot)} with #{clinician_name}"

        _ ->
          "book #{slot_label(slot)} with #{clinician_name}"
      end

    success("Shall I #{description}? Nothing has been changed yet.", %{
      proposal: id,
      slot: slot,
      change: operation,
      revision: revision,
      clinician: clinician,
      clinician_name: clinician_name
    })
  end

  defp verified_slot?(exists, offered, input, clinician),
    do: exists and offered and Map.get(input, :clinician) == clinician

  defp patient_insurance(db, patient) do
    case query(
           db,
           "SELECT insurance_carrier,insurance_revision,insurance_needs_update FROM patients WHERE id=?",
           [patient]
         ) do
      [[carrier, revision, pending]] ->
        %{carrier: carrier, revision: revision, needs_update: pending == 1, confirmed: false}

      _ ->
        nil
    end
  end

  defp insurance_state(db, lookup, session) do
    case matched_identity(db, lookup, session) do
      patient when is_binary(patient) ->
        current = patient_insurance(db, patient)

        review =
          query(
            db,
            "SELECT request_id FROM insurance_reviews WHERE lookup_request=? AND session=? AND patient=? AND carrier=? AND revision=? AND status='confirmed'",
            [lookup, session, patient, current.carrier, current.revision]
          )

        case review do
          [[id]] when not current.needs_update ->
            Map.merge(current, %{confirmed: true, insurance_request: id})

          _ ->
            Map.put(current, :insurance_request, nil)
        end

      _ ->
        nil
    end
  end

  defp proposal_insurance?(db, id) do
    case query(db, "SELECT input FROM receipts WHERE id=?", [id]) do
      [[encoded]] ->
        input = JSON.decode!(encoded)

        case insurance_state(db, input["lookup_request"], input["session"]) do
          %{confirmed: true, insurance_request: proof} -> proof == input["insurance_request"]
          _ -> false
        end

      _ ->
        false
    end
  end

  defp reviewed_insurance?(db, input) do
    case insurance_state(db, input.lookup_request, input.session) do
      %{confirmed: true, insurance_request: request} ->
        request == Map.get(input, :insurance_request)

      _ ->
        false
    end
  end

  defp matched_identity(db, request, session) do
    case query(db, "SELECT input,result FROM receipts WHERE id=?", [request]) do
      [[input, result]] ->
        case {JSON.decode!(input), JSON.decode!(result)} do
          {%{"operation" => "lookup", "session" => ^session},
           %{"status" => "completed", "facts" => %{"patient" => patient}}} ->
            patient

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp slot_fact([id, date, provider]) do
    %{
      id: id,
      date: date,
      time: String.slice(id, 11, 5),
      clinician:
        Enum.find_value(clinicians(), fn {key, name} -> if name == provider, do: key end),
      clinician_name: provider
    }
  end

  defp date_label(date) do
    date = Date.from_iso8601!(String.slice(date, 0, 10))

    day =
      Enum.at(
        ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday),
        Date.day_of_week(date) - 1
      )

    "#{day} November #{date.day}"
  end

  defp time_label(slot) do
    hour = slot |> String.slice(11, 2) |> String.to_integer()
    minute = String.slice(slot, 14, 2)

    "#{if rem(hour, 12) == 0, do: 12, else: rem(hour, 12)}:#{minute} #{if hour >= 12, do: "PM", else: "AM"}"
  end

  defp slot_label(slot), do: "#{date_label(slot)} at #{time_label(slot)}"

  defp success(summary, facts), do: %{status: "completed", summary: summary, facts: facts}
  defp failure(summary), do: %{status: "failed", summary: summary, facts: %{}}

  defp query(db, sql, params) do
    {:ok, statement} = SQL.prepare(db, sql)

    try do
      :ok = SQL.bind(statement, params)
      {:ok, rows} = SQL.fetch_all(db, statement)
      rows
    after
      SQL.release(db, statement)
    end
  end

  def terminate(_reason, db), do: SQL.close(db)
end
