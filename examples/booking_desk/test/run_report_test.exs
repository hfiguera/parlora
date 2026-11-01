defmodule BookingDesk.RunReportTest do
  use ExUnit.Case, async: true
  alias BookingDesk.RunReport

  test "manual booking and reminder observations do not inherit replay milestone failures" do
    report =
      RunReport.microphone(
        [%{operation: "confirm", request_id: "booking"}],
        [["booking", "patient", "2026-11-05T10:15:00", "booked", "BD-123"]],
        [["booking", "patient", "+12025550188", "2026-11-04T17:15:00Z", "simulated", "consent"]],
        []
      )

    assert report.evaluation == "not_evaluated"
    assert report.scenario == "interactive-microphone"
    assert report.passed == nil
    assert report.checks == %{}

    assert report.observed == %{
             booked_appointments: 1,
             simulated_reminders: 1,
             adapter_failures: 0
           }
  end

  test "persisted bookings from other calls and cancelled jobs cannot count as this call's outcomes" do
    appointments = [
      ["older", "patient", "2026-11-04T10:15:00", "booked", "BD-old"],
      ["current", "patient", "2026-11-05T10:15:00", "cancelled", "BD-current"]
    ]

    reminders = [
      ["older", "patient", "+12025550188", "due", "simulated", "consent"],
      ["current", "patient", "+12025550188", "due", "cancelled", "consent"]
    ]

    report =
      RunReport.microphone(
        [%{operation: "confirm", request_id: "current"}],
        appointments,
        reminders,
        [:provider]
      )

    assert report.observed == %{
             booked_appointments: 0,
             simulated_reminders: 0,
             adapter_failures: 1
           }

    assert RunReport.microphone([], appointments, reminders, []).observed.booked_appointments == 0
  end
end
