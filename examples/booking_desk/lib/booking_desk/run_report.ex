defmodule BookingDesk.RunReport do
  @moduledoc "Observed microphone outcomes are separate from scripted replay qualification."

  def microphone(submissions, appointments, reminder_jobs, failures) do
    confirmations =
      submissions
      |> Enum.filter(&(&1.operation == "confirm" and is_binary(Map.get(&1, :request_id))))
      |> MapSet.new(& &1.request_id)

    booked =
      appointments
      |> Enum.filter(fn [id, _, _, status, _] ->
        status == "booked" and MapSet.member?(confirmations, id)
      end)
      |> MapSet.new(&hd/1)

    reminders =
      Enum.count(reminder_jobs, fn [appointment, _, _, _, status, _] ->
        status == "simulated" and MapSet.member?(booked, appointment)
      end)

    %{
      scenario: "interactive-microphone",
      evaluation: "not_evaluated",
      passed: nil,
      checks: %{},
      observed: %{
        booked_appointments: MapSet.size(booked),
        simulated_reminders: reminders,
        adapter_failures: length(failures)
      }
    }
  end
end
