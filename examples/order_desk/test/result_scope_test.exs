defmodule OrderDesk.ResultScopeTest do
  use ExUnit.Case, async: false

  test "status does not preload instructions or items for later unverified answers" do
    {:ok, %{last_answer: %{summary: status}}} =
      OrderDesk.Lookup.run(%{input: %{operation: "status", order: "124"}}, %{})

    assert status =~ "out for delivery"
    assert status =~ "Tracking reference"
    refute status =~ "Delivery instructions"
    refute status =~ "Desk lamp"

    {:ok, %{last_answer: %{summary: instructions}}} =
      OrderDesk.Lookup.run(%{input: %{operation: "instructions", order: "124"}}, %{})

    assert instructions =~ "Saved delivery instructions for order 124:"
    assert instructions =~ "This is a database read; no changes were made."
  end
end
