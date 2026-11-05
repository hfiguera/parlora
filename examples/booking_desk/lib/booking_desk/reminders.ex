defmodule BookingDesk.Reminders do
  @moduledoc "Appointment-scoped SMS consent and a simulated reminder outbox. No messages are sent."
  alias Exqlite.Sqlite3, as: SQL

  @number_consent_notice "Any number you supplied still needs a separate readback and confirmation."

  def init(db) do
    SQL.execute(db, """
    CREATE TABLE IF NOT EXISTS reminder_reviews(appointment TEXT PRIMARY KEY,session TEXT,lookup_request TEXT,patient TEXT,status TEXT,destination TEXT,original_phone TEXT,request_id TEXT);
    CREATE TABLE IF NOT EXISTS reminder_jobs(appointment TEXT PRIMARY KEY,patient TEXT,destination TEXT,scheduled_at TEXT,status TEXT,consent_request TEXT);
    """)
  end

  def phone(value) when is_binary(value) do
    digits = String.replace(value, ~r/[\s()+.\-]/, "")
    digits = if byte_size(digits) == 10, do: "1" <> digits, else: digits
    if Regex.match?(~r/^1[2-9][0-9]{2}[2-9][0-9]{6}$/, digits), do: "+" <> digits
  end

  def phone(_), do: nil

  def offer(db, patient) do
    [[stored]] = q(db, "SELECT phone FROM patients WHERE id=?", [patient])
    last_four = if phone(stored), do: String.slice(phone(stored), -4, 4)

    contact =
      if last_four,
        do: "Verified contact reference: the number on file ends in #{spoken(last_four)}.",
        else: "There is no usable phone number on file; never invent one."

    {"Ask: Would you like a text reminder 24 hours before your appointment? #{contact} This is reference data, not consent. Wait for their answer, delegate opt-in, and use the current backend destination question before asking for separate number confirmation.",
     %{status: "offered", last_four: last_four}}
  end

  def state(db, booking, lookup, session) do
    with [[encoded, result]] <- q(db, "SELECT input,result FROM receipts WHERE id=?", [booking]),
         %{
           "operation" => "confirm",
           "lookup_request" => ^lookup,
           "session" => ^session,
           "patient" => patient
         } <- JSON.decode!(encoded),
         %{"status" => "completed", "facts" => %{"appointment" => ^booking}} <-
           JSON.decode!(result),
         [[slot, original]] <-
           q(
             db,
             "SELECT a.slot,p.phone FROM appointments a JOIN patients p ON p.id=a.patient WHERE a.id=? AND a.patient=? AND a.status='booked'",
             [booking, patient]
           ) do
      current =
        case q(
               db,
               "SELECT status,destination,original_phone,request_id FROM reminder_reviews WHERE appointment=? AND session=? AND lookup_request=? AND patient=?",
               [booking, session, lookup, patient]
             ) do
          [[status, destination, stored, request]] ->
            %{
              status: status,
              destination: destination,
              original_phone: stored,
              request_id: request
            }

          _ ->
            %{status: "offered", destination: nil, original_phone: original, request_id: booking}
        end

      Map.merge(current, %{
        appointment: booking,
        patient: patient,
        slot: slot,
        last_four: if(phone(original), do: String.slice(phone(original), -4, 4))
      })
    else
      _ -> nil
    end
  end

  def execute(
        db,
        %{booking_request: _, lookup_request: _, session: _, patient: _, reminder_revision: _} =
          input,
        id
      ) do
    current = state(db, input.booking_request, input.lookup_request, input.session)

    cond do
      current == nil or current.patient != input.patient ->
        fail(
          "The appointment could not be verified. No reminder was changed; do not submit another booking."
        )

      input.reminder_revision != current.request_id ->
        fail(
          "The reminder details changed. Ask about the current destination again. The appointment remains booked."
        )

      current.status in ["scheduled", "declined"] ->
        ok("The reminder preference is already saved. Do not book again.", current)

      true ->
        change(db, current, input, id)
    end
  end

  def execute(_, _, _),
    do: fail("Missing reminder authorization. The appointment remains booked.")

  defp change(db, s, %{operation: "reminder_opt_in"} = input, id) when s.status == "offered" do
    destination = phone(s.original_phone)
    status = if destination, do: "verify_existing", else: "need_number"
    save(db, s, input, id, status, destination)

    question =
      if destination,
        do: "Can we send it to the number ending in #{spoken(String.slice(destination, -4, 4))}?",
        else: "What phone number should we use for the reminder?"

    ok(
      "The caller opted in to a simulated text reminder 24 hours before this appointment. #{question} Wait for their confirmation; nothing is scheduled yet.",
      %{status: status, last_four: s.last_four, reminder_revision: id}
    )
  end

  defp change(db, s, %{operation: "reminder_decline"} = input, id) do
    save(db, s, input, id, "declined", nil)

    ok("No text reminder will be scheduled. The appointment remains booked.", %{
      status: "declined",
      simulated: true
    })
  end

  defp change(db, s, %{operation: "reminder_change"} = input, id)
       when s.status in ["verify_existing", "need_number", "verify_new"] do
    [[actual]] = q(db, "SELECT phone FROM patients WHERE id=?", [s.patient])
    save(db, %{s | original_phone: actual}, input, id, "need_number", nil)

    ok(
      "Ask what phone number to use for the reminder. Do not change the number on file until the caller confirms its complete readback.",
      %{status: "need_number"}
    )
  end

  defp change(db, s, %{operation: "reminder_number", phone: candidate} = input, id)
       when s.status in ["need_number", "verify_existing", "verify_new"] do
    if phone(candidate) == candidate do
      save(db, s, input, id, "verify_new", candidate)

      ok(
        "Read back the complete phone number #{spoken(candidate)} and ask if it is correct. Wait for explicit confirmation before saving or scheduling.",
        %{status: "verify_new", destination: candidate, reminder_revision: id}
      )
    else
      fail(
        "That is not a complete supported US phone number. Ask for all ten digits. No phone or appointment was changed."
      )
    end
  end

  defp change(
         db,
         s,
         %{operation: "reminder_confirm", destination: destination, readback_verified: true} =
           input,
         id
       )
       when s.status in ["verify_existing", "verify_new"] do
    [[actual]] = q(db, "SELECT phone FROM patients WHERE id=?", [s.patient])

    cond do
      destination != s.destination or phone(destination) != destination ->
        fail(
          "The destination does not match the number awaiting confirmation. Nothing was scheduled."
        )

      actual != s.original_phone ->
        fail(
          "The phone on file changed. Verify the current number again. The appointment remains booked."
        )

      q(db, "SELECT id FROM patients WHERE phone IN (?,?) AND id != ?", [
        destination,
        String.replace_prefix(destination, "+1", ""),
        s.patient
      ]) != [] ->
        fail(
          "That number is already associated with another fictional record. No number or appointment was changed."
        )

      true ->
        # The demo dates are after the November DST change: America/Denver is UTC-07:00.
        {:ok, appointment, _} = DateTime.from_iso8601(String.slice(s.slot, 0, 19) <> "-07:00")
        scheduled = appointment |> DateTime.add(-86_400, :second) |> DateTime.to_iso8601()

        q(db, "INSERT INTO reminder_jobs VALUES(?,?,?,?,'simulated',?)", [
          s.appointment,
          s.patient,
          destination,
          scheduled,
          id
        ])

        if s.status == "verify_new",
          do: q(db, "UPDATE patients SET phone=? WHERE id=?", [destination, s.patient])

        save(db, s, input, id, "scheduled", destination)

        ok(
          "Your text reminder is scheduled for 24 hours before your appointment. The demo saved a simulated job only; no real text will be sent. Do not repeat the booking or confirmation code.",
          %{
            status: "scheduled",
            appointment: s.appointment,
            last_four: String.slice(destination, -4, 4),
            scheduled_at: scheduled,
            simulated: true
          }
        )
    end
  end

  defp change(_, _, _, _),
    do:
      fail(
        "Confirm the reminder offer and its destination first. The appointment remains booked."
      )

  def cancel(db, appointment),
    do: q(db, "UPDATE reminder_jobs SET status='cancelled' WHERE appointment=?", [appointment])

  def jobs(db),
    do:
      q(
        db,
        "SELECT appointment,patient,destination,scheduled_at,status,consent_request FROM reminder_jobs ORDER BY appointment",
        []
      )

  defp save(db, s, input, id, status, destination),
    do:
      q(db, "INSERT OR REPLACE INTO reminder_reviews VALUES(?,?,?,?,?,?,?,?)", [
        s.appointment,
        input.session,
        input.lookup_request,
        s.patient,
        status,
        destination,
        s.original_phone,
        id
      ])

  def spoken(value),
    do:
      value
      |> String.replace_prefix("+1", "")
      |> String.graphemes()
      |> Enum.map_join(
        " ",
        &Map.fetch!(
          Map.new(
            Enum.zip(
              ~w(0 1 2 3 4 5 6 7 8 9),
              ~w(zero one two three four five six seven eight nine)
            )
          ),
          &1
        )
      )

  def readback?(text, expected) do
    readback_digits(text) == String.replace_prefix(expected, "+1", "") and
      String.contains?(text, "?")
  end

  def destination_question?(text, expected) do
    question = text |> String.trim() |> String.split(~r/(?<=[.!?])\s+/u) |> List.last()

    readback?(text, expected) and
      Regex.match?(
        ~r/^(?:can|could|may) (?:we|I) (?:send (?:it|the reminder|that reminder|the text reminder)|text) to (?:(?:your|the) )?(?:(?:(?:cell|phone)(?: number)?|number)(?: ending in)? )?(?:[0-9+() .-]|zero|oh|one|two|three|four|five|six|seven|eight|nine)+\?$/i,
        question
      )
  end

  @doc "Conversation cue for replay or a semantically classified reply; not proof of consent."
  def possible_offer?(text),
    do:
      Regex.match?(~r/text|SMS/i, text) && Regex.match?(~r/remind/i, text) &&
        String.contains?(text, "?")

  def offer_question,
    do:
      "Would you like a text reminder 24 hours before your appointment? " <>
        @number_consent_notice

  def offer_question?(text) do
    question =
      text
      |> String.trim()
      |> String.replace_suffix(" " <> @number_consent_notice, "")
      |> String.split(~r/(?<=[.!?])\s+/u)
      |> List.last()
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/\btwenty[- ]four\b/i, "24")

    Regex.match?(
      ~r/^Would you like a (?:text|SMS) reminder(?: (?:24 hours before(?: (?:your|the) appointment)?|for this appointment))?\?$/i,
      question
    )
  end

  def readback_digits(text) do
    words =
      Map.new(
        Enum.zip(
          ~w(zero oh one two three four five six seven eight nine),
          ~w(0 0 1 2 3 4 5 6 7 8 9)
        )
      )

    Regex.scan(~r/\b(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)\b|[0-9]/i, text)
    |> List.flatten()
    |> Enum.map_join(&Map.get(words, String.downcase(&1), &1))
  end

  defp ok(summary, facts), do: %{status: "completed", summary: summary, facts: %{reminder: facts}}
  defp fail(summary), do: %{status: "failed", summary: summary, facts: %{}}

  defp q(db, sql, args) do
    {:ok, st} = SQL.prepare(db, sql)

    try do
      :ok = SQL.bind(st, args)
      {:ok, rows} = SQL.fetch_all(db, st)
      rows
    after
      SQL.release(db, st)
    end
  end
end
