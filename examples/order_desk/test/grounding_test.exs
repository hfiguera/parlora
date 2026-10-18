defmodule OrderDesk.GroundingTest do
  use ExUnit.Case

  test "status results retain the database timing without inferring a date" do
    for {order, expected} <- [{"124", "out for delivery"}, {"123", "shipped; expected Friday"}] do
      assert {:ok, %{last_answer: %{summary: summary}}} =
               OrderDesk.Lookup.run(%{input: %{order: order, operation: "status"}}, %{})

      assert summary =~ "Order #{order} is #{expected}."
      assert summary =~ "do not infer a delivery date"
      refute summary =~ "today"
    end
  end
end
