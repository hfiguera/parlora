defmodule BookingDesk.Recovery do
  @moduledoc "Read-only recovery controls and questions derived from the current verified flow."

  def command(text) do
    text =
      text
      |> String.downcase()
      |> String.replace("’", "'")
      |> String.replace(~r/[.,!?]/u, "")
      |> String.trim()

    cond do
      text in [
        "start over",
        "let's start over",
        "can we start over",
        "restart",
        "reset the conversation"
      ] ->
        {:ok, %{"intent" => "restart"}}

      text in [
        "repeat that",
        "say that again",
        "please repeat",
        "what did you ask",
        "can you repeat that"
      ] ->
        {:ok, %{"intent" => "repeat"}}

      text in ["try again", "please try again", "retry"] ->
        {:ok, %{"intent" => "retry"}}

      text in ["back to the reminder", "return to the reminder", "resume the reminder"] ->
        {:ok, %{"intent" => "reminder"}}

      true ->
        nil
    end
  end

  def pending_write?(nil), do: false

  def pending_write?(task),
    do:
      task.input.operation in ~w(confirm reminder_confirm) and
        task.status not in [:completed, :failed, :cancelled]

  def question(state, latest) do
    cond do
      state.proposal != nil ->
        proposal_question(state.proposal)

      state.insurance == nil ->
        "Could I have your full name and date of birth so I can find your record?"

      not state.insurance.confirmed ->
        BookingDesk.Insurance.question(state.insurance)

      pending_reminder?(state.reminder) ->
        BookingDesk.ReminderPolicy.question(state.reminder, state.conversation.phone)

      is_binary(get_in(latest, [:clarification, :message])) ->
        latest.clarification.message

      state.verified_offers != [] ->
        offers_question(state.verified_offers)

      true ->
        "Which date and doctor would you like to check? Nothing has been changed."
    end
  end

  defp pending_reminder?(nil), do: false
  defp pending_reminder?(reminder), do: reminder.status not in ["scheduled", "declined"]

  def proposal_question(%{change: "cancel", slot: slot}),
    do:
      "Should I cancel your appointment on #{String.slice(slot, 0, 10)} at #{String.slice(slot, 11, 5)}?"

  def proposal_question(proposal) do
    doctor = BookingDesk.Store.clinicians()[proposal.clinician_id]
    action = if proposal.change == "reschedule", do: "reschedule", else: "book"

    "Should I #{action} #{String.slice(proposal.slot, 0, 10)} at #{String.slice(proposal.slot, 11, 5)} with #{doctor}?"
  end

  defp offers_question(offers) do
    options =
      offers
      |> Enum.take(4)
      |> Enum.map_join("; ", fn slot ->
        "#{slot.date} at #{slot.time} with #{BookingDesk.Store.clinicians()[slot.clinician]}"
      end)

    "The verified options are #{options}. Which one would you like? Nothing has been booked."
  end
end
