defmodule OptionalBackendConsumerTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, Error, Limits}

  test "the dependency graph contains only the explicitly selected framework" do
    assert :ok = OptionalBackendConsumer.check_dependencies!()
  end

  test "uninstalled backend adapters reject selection before starting work" do
    profile = Application.fetch_env!(:optional_backend_consumer, :profile)

    init = %AdapterInit{
      session_id: "optional",
      adapter_id: "backend",
      generation: 0,
      event_sink: self(),
      limits: %Limits{}
    }

    for {app, adapter, options} <- [
          {:jido, Parlora.Backends.Jido, [agent: __MODULE__, result: fn _ -> %{} end]},
          {:sagents, Parlora.Backends.Sagents,
           [agent: fn _ -> nil end, result: fn _ -> %{} end, completion_tool: "finish"]},
          {:legion, Parlora.Backends.Legion, [execution: fn _ -> nil end]}
        ],
        app != profile do
      assert {:error, %Error{code: :unsupported, message: message}} =
               adapter.start_link(init, options)

      assert message =~ "Install optional #{app}"
    end
  end
end
