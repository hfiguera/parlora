defmodule OrderDesk.TwilioGateTest do
  use ExUnit.Case, async: false
  alias OrderDesk.TwilioGate

  setup do
    gate =
      start_supervised!(
        {TwilioGate, public_url: "https://example.com", phone_number: "+15555550123"}
      )

    %{gate: gate}
  end

  test "retries share an unclaimed ticket, each ticket admits once, and caller ID grants no identity" do
    params = %{
      "CallSid" => "CA" <> String.duplicate("1", 32),
      "To" => "+15555550123",
      "Direction" => "inbound",
      "From" => "+15555550999"
    }

    assert {:ok, url} = TwilioGate.issue(params)
    assert {:ok, ^url} = TwilioGate.issue(params)
    ticket = URI.parse(url).path |> String.split("/") |> List.last()
    assert {:ok, call} = TwilioGate.claim(ticket)
    assert call == params["CallSid"]
    assert {:error, :invalid_ticket} = TwilioGate.claim(ticket)
    assert {:error, :already_claimed} = TwilioGate.issue(params)
    assert {:error, :call_not_allowed} = TwilioGate.issue(%{params | "To" => "+15555550777"})

    assert {:error, :call_not_allowed} =
             TwilioGate.issue(%{params | "Direction" => "outbound-api"})
  end

  test "expired tickets fail closed", %{gate: gate} do
    params = %{"CallSid" => "call", "To" => "+15555550123", "Direction" => "inbound"}
    {:ok, url} = TwilioGate.issue(params)
    ticket = URI.parse(url).path |> String.split("/") |> List.last()

    :sys.replace_state(gate, fn state ->
      put_in(state, [:tickets, ticket, :expires], System.monotonic_time(:millisecond) - 1)
    end)

    assert {:error, :expired} = TwilioGate.claim(ticket)
    assert {:error, :expired} = TwilioGate.issue(params)
  end

  test "request admission and retained call identities have finite bounds" do
    for _n <- 1..20, do: assert(:ok == TwilioGate.admit_request())
    assert {:error, :rate_limited} = TwilioGate.admit_request()

    for n <- 1..64 do
      assert {:ok, _url} =
               TwilioGate.issue(%{
                 "CallSid" => "call-#{n}",
                 "To" => "+15555550123",
                 "Direction" => "inbound"
               })
    end

    assert {:error, :call_capacity} =
             TwilioGate.issue(%{
               "CallSid" => "overflow",
               "To" => "+15555550123",
               "Direction" => "inbound"
             })
  end
end
