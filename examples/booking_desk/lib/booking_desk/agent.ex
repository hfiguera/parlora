defmodule BookingDesk.Action do
  @moduledoc "Jido executes scheduling operations, independently of audio and policy work."
  use Jido.Action,
    name: "schedule_appointment",
    schema: [
      input: [type: :map, required: true],
      request_id: [type: :string],
      task_id: [type: :string],
      task_revision: [type: :integer]
    ]

  def run(params, _context) do
    delays = Application.fetch_env!(:booking_desk, :delays)

    delay =
      case params.input.operation do
        "availability" -> Map.get(delays, params.input.date, 0)
        "confirm" -> Map.get(delays, "booking", 0)
        _ -> 0
      end

    Process.sleep(delay)
    result = BookingDesk.Store.execute(params.input, params.request_id)

    # Business failure is a completed Jido action carrying a verified failed result.
    {:ok, %{status: :completed, last_answer: result}}
  end
end

defmodule BookingDesk.Agent do
  @moduledoc "Jido host for deterministic scheduling actions."
  use Jido.Agent,
    name: "booking_desk",
    schema: [status: [type: :atom, default: :idle], last_answer: [type: :map, default: %{}]],
    signal_routes: [{"parlora.request", BookingDesk.Action}]
end
