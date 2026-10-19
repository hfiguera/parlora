defmodule Parlora.JSONBoundaryTest do
  use ExUnit.Case, async: true

  alias Parlora.Backends.Legion.Collector
  alias Parlora.Providers.Grok.{Calls, Protocol}
  alias Parlora.TestSupport.JSONValue

  test "Grok tool output stays a JSON string with null, Unicode and escaped text" do
    value = %{
      result: [nil, true, false, 123, 1.25, "Olá 👋\n\"quoted\"\\path"],
      date: ~D[2026-10-19]
    }

    command = Protocol.result("call", value)
    assert is_binary(command.item.output)
    assert command.item.output =~ "null"
    assert command.item.output =~ ~S(\n\"quoted\"\\path)

    assert %{"item" => %{"call_id" => "call", "output" => output}} =
             command |> JSON.encode!() |> JSON.decode!()

    assert JSON.decode!(output) == %{
             "result" => [nil, true, false, 123, 1.25, "Olá 👋\n\"quoted\"\\path"],
             "date" => "2026-10-19"
           }
  end

  test "malformed Grok tool arguments cannot admit work or leak decoder contents" do
    for encoded <- [~s({"request":), <<?{, 255, ?}>>, "null", "[]"] do
      assert {:error, error} =
               Calls.admit(Calls.new(16), %{
                 "call_id" => "call",
                 "name" => Protocol.function(),
                 "arguments" => encoded
               })

      assert error.code == :invalid_argument
      assert error.details == %{}
    end
  end

  test "collector accepts native JSON values and explicit JSON encoders without changing facts" do
    value = %{optional: nil, count: 123, text: "Olá 👋", date: ~D[2026-10-19]}

    for native <- [value, %JSONValue{value: value, private: "not serialized"}] do
      collector = collector(native)
      assert {:ok, ^native} = Collector.operation(collector, "lookup")
      assert {:ok, "Native result ready"} = Collector.complete(collector, nil)
      assert Collector.result(collector) == %{"lookup" => native}
    end

    refute JSON.encode!(%JSONValue{value: value, private: "not serialized"}) =~ "not serialized"
  end

  test "collector rejects invalid UTF-8 and unsupported terms without admitting completion" do
    for value <- [<<255>>, {:private, "secret"}, self(), %URI{host: "secret"}] do
      collector = collector(%{nested: [value]})
      assert {:error, "Native operation failed"} = Collector.operation(collector, "lookup")
      assert {:error, "Execution is sealed"} = Collector.complete(collector, nil)
      assert Collector.result(collector) == nil
      assert Process.alive?(collector)
    end
  end

  defp collector(value) do
    execution = %{
      operations: %{"lookup" => fn -> {:ok, value} end},
      result: &Function.identity/1
    }

    start_supervised!(%{
      id: make_ref(),
      start: {Collector, :start_link, [execution, 4]}
    })
  end
end
