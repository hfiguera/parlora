defmodule BookingDesk.Application do
  use Application

  def start(_type, _args) do
    judgment =
      case System.get_env("TYPESAFE_API_KEY") do
        key when is_binary(key) and key != "" ->
          [
            {TypeSafe.Client,
             name: BookingDesk.TypeSafe,
             api_key: key,
             model: Application.fetch_env!(:booking_desk, :jev_model),
             timeout: 2_000,
             max_concurrency: 2,
             max_queue: 4,
             retry: [max_attempts: 1]}
          ]

        _ ->
          []
      end

    Supervisor.start_link(
      [
        {Jido, name: BookingDesk.Jido},
        {BookingDesk.Store, path: Application.fetch_env!(:booking_desk, :database)},
        {Task.Supervisor, name: BookingDesk.ReadbackTasks},
        {BookingDesk.Judgment, []},
        {Task.Supervisor, name: BookingDesk.GuardTasks, max_children: 8},
        {DynamicSupervisor, name: BookingDesk.CallGuards, strategy: :one_for_one},
        {Task.Supervisor, name: BookingDesk.IdentityTasks, max_children: 2},
        {BookingDesk.Identity.Extractor, []},
        Supervisor.child_spec(
          {BookingDesk.Identity.Extractor,
           [
             name: BookingDesk.InsuranceExtractor,
             field: :insurance,
             evaluator: &BookingDesk.Insurance.extract/1
           ]},
          id: BookingDesk.InsuranceExtractor
        ),
        Supervisor.child_spec(
          {BookingDesk.Identity.Extractor,
           [
             name: BookingDesk.PhoneExtractor,
             field: :phone,
             evaluator: &BookingDesk.Phone.extract/1
           ]},
          id: BookingDesk.PhoneExtractor
        )
      ] ++ judgment,
      strategy: :one_for_one,
      name: BookingDesk.Supervisor
    )
  end
end
