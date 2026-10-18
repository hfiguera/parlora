if Code.ensure_loaded?(Sagents.Agent) do
  defmodule OrderDesk.SagentsFixture do
    @moduledoc false
    @behaviour LangChain.ChatModels.ChatModel
    alias LangChain.Message
    alias LangChain.Message.ToolCall
    defstruct [:observer, calls: [], arguments: %{}, callbacks: [], stream: false]

    @impl true
    def call(model, messages, _tools) do
      step = Enum.count(messages, &(&1.role == :tool))
      name = Enum.at(model.calls, step, "finish")
      send(model.observer, {:fixture_tool, name})

      {:ok,
       Message.new_assistant!(%{
         tool_calls: [
           ToolCall.new!(%{
             name: name,
             call_id: "call-#{step}",
             status: :complete,
             arguments: model.arguments
           })
         ]
       })}
    end

    @impl true
    def retry_on_fallback?(_error), do: false
    @impl true
    def serialize_config(_model), do: %{}
    @impl true
    def restore_from_map(_map), do: {:error, "Fixture only"}
  end

  defmodule OrderDesk.SagentsIntegrationTest do
    use ExUnit.Case
    alias Parlora.{AdapterInit, BackendRequest, Event, Limits}
    alias Parlora.Backends.Sagents
    alias OrderDesk.{SagentsAgent, SagentsFixture, Store}

    test "substitution returns the same database status as Jido" do
      input = %{order: "124", operation: "status"}
      {:ok, %{last_answer: answer}} = OrderDesk.Lookup.run(%{input: input}, %{})
      result = execute(input, ["lookup", "finish"])
      assert result.summary == answer.summary
      assert result.facts == %{order: "124"}
    end

    test "two distinct reads can be orchestrated in either order" do
      result =
        execute(%{order: "124", operation: "overview"}, ["read_items", "read_status", "finish"])

      assert result.summary =~ "out for delivery"
      assert result.summary =~ "contains"
      assert_receive {:fixture_tool, "read_items"}
      assert_receive {:fixture_tool, "read_status"}
    end

    test "early finish and repeated draft calls cannot save or repeat the draft" do
      actor = Parlora.ID.new()
      {:ok, before_order} = Store.order("825")
      before_changes = Store.dashboard(actor).changes

      result =
        execute(
          %{
            order: "825",
            operation: "delivery",
            actor: actor,
            instructions: "Leave at reception"
          },
          ["finish", "lookup", "lookup", "finish"]
        )

      assert result.summary =~ "Nothing has been changed"
      assert {:ok, ^before_order} = Store.order("825")
      dashboard = Store.dashboard(actor)
      assert length(dashboard.proposals) == 1
      assert dashboard.changes == before_changes
    end

    test "model-supplied arguments never expand the task's authority" do
      actor = Parlora.ID.new()
      input = %{order: "825", operation: "delivery", actor: actor, instructions: "Reception"}

      backend =
        start_backend(["lookup", "finish"], %{"order" => "123", "instructions" => "Invented"})

      assert :ok = Sagents.submit(backend, request(input))
      assert_receive {:parlora_event, %Event{type: :request_uncertain}}, 1_000
      assert Store.dashboard(actor).proposals == []
    end

    defp execute(input, calls) do
      backend = start_backend(calls)
      assert :ok = Sagents.submit(backend, request(input))
      assert_receive {:parlora_event, %Event{type: :request_completed, payload: result}}, 1_000
      result
    end

    defp start_backend(calls, arguments \\ %{}) do
      observer = self()

      config = %{
        model_fixture: %SagentsFixture{calls: calls, observer: observer, arguments: arguments}
      }

      init = %AdapterInit{
        session_id: "fixture",
        adapter_id: "backend",
        generation: 0,
        event_sink: observer,
        limits: %Limits{job_timeout_ms: 1_000}
      }

      {:ok, pid} =
        Sagents.start_link(init,
          agent: &SagentsAgent.build(&1, config),
          completion_tool: "finish",
          max_runs: 6,
          result: &SagentsAgent.result/1
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      pid
    end

    defp request(input),
      do: %BackendRequest{
        id: Parlora.ID.new(),
        task_id: "task",
        task_revision: 1,
        provider_generation: 0,
        input: input
      }
  end
else
  defmodule OrderDesk.WithoutSagentsTest do
    use ExUnit.Case

    test "optional adapter reports unsupported without installing the framework" do
      assert {:error, %{code: :unsupported}} =
               Parlora.Backends.Sagents.start_link(
                 %Parlora.AdapterInit{
                   session_id: "optional",
                   adapter_id: "backend",
                   generation: 0,
                   event_sink: self(),
                   limits: %Parlora.Limits{}
                 },
                 []
               )

      assert {Parlora.Backends.Jido, _options} = OrderDesk.Backend.selected()
      refute Code.ensure_loaded?(LangChain.Chains.LLMChain)
      if not Code.ensure_loaded?(Legion), do: refute(Code.ensure_loaded?(Ecto.Schema))
      refute Code.ensure_loaded?(Phoenix.PubSub)
    end
  end
end
