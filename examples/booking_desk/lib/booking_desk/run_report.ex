defmodule BookingDesk.RunReport do
  @moduledoc "Observed microphone outcomes are separate from scripted replay qualification."

  @doc "Provider overrides recorded in reports, excluding API credentials."
  def provider_options(options),
    do:
      options
      |> Keyword.delete(:api_key)
      |> Map.new(fn {key, value} -> {key, option_value(value)} end)

  defp option_value(value) when is_list(value) and value != [] do
    if Keyword.keyword?(value),
      do: Map.new(value, fn {key, item} -> {key, option_value(item)} end),
      else: Enum.map(value, &option_value/1)
  end

  defp option_value(value), do: value

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
