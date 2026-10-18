# Run in each standalone consumer. Emits only synthetic setup/tool fixtures.
alias Parlora.Providers.Gemini.{Calls, Protocol}

{:ok, config} =
  Protocol.start(
    [api_key: "offline-placeholder", instructions: OrderDesk.Voice.instructions(:browser)],
    %Parlora.AudioFormat{}
  )

{:new, calls} =
  Calls.admit(Calls.new(16), %{
    "id" => "first-call",
    "name" => Protocol.function(),
    "args" => %{"request" => "Check order 124"}
  })

{:ok, result, _calls} = Calls.context(calls, "first-call", "Order 124 is out for delivery.")
[destination] = System.argv()

File.write!(
  destination,
  Jason.encode!(%{setup: config.setup, first_result: result}, pretty: true)
)
