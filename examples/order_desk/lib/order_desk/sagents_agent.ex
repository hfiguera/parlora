defmodule OrderDesk.SagentsAgent do
  @moduledoc "Task-scoped tools whose native results, rather than model prose, become facts."

  def build(request, config) do
    model =
      Map.get(config, :model_fixture) ||
        apply(LangChain.ChatModels.ChatOpenAI, :new!, [
          %{
            api_key: config.api_key,
            model: config.model,
            reasoning_mode: true,
            reasoning_effort: "none",
            temperature: 1.0,
            stream: false,
            receive_timeout: 8_000,
            max_tokens: 1_000
          }
        ])

    token = make_ref()
    operation = Map.get(request.input, :operation, "status")

    reads =
      if operation == "overview",
        do: [{"read_status", "status"}, {"read_items", "items"}],
        else: [{"lookup", operation}]

    tools =
      Enum.map(reads, fn {name, action} ->
        tool(name, "Execute the admitted #{action} operation for this exact order", fn ->
          case Process.get({token, name}) do
            nil ->
              input = Map.put(request.input, :operation, action)

              {:ok, %{last_answer: answer}} =
                OrderDesk.Operations.execute(%{
                  input: input,
                  request_id: request.id,
                  task_id: request.task_id,
                  task_revision: request.task_revision
                })

              Process.put({token, name}, answer)
              {:ok, answer.summary}

            answer ->
              {:ok, answer.summary}
          end
        end)
      end)

    finish =
      tool(
        "finish",
        "Return authoritative results after all required reads; accepts no claims",
        fn ->
          answers = Enum.map(reads, fn {name, _action} -> Process.get({token, name}) end)

          if Enum.any?(answers, &is_nil/1) do
            {:error, "Execute every required operation before finishing"}
          else
            mapped = %{
              status: :completed,
              facts: %{order: request.input.order},
              summary: Enum.map_join(answers, " ", & &1.summary)
            }

            {:ok, "Application result ready", mapped}
          end
        end
      )

    agent =
      apply(Sagents.Agent, :new!, [
        %{
          model: model,
          middleware: [],
          tools: tools ++ [finish],
          base_system_prompt:
            "Execute only the admitted task. Call #{Enum.map_join(reads, ", ", &elem(&1, 0))}, then finish. Do not invent facts or change tool arguments. Browser confirmation is required to save delivery instructions."
        },
        [replace_default_middleware: true]
      ])

    message =
      apply(LangChain.Message, :new_user!, [
        "Perform the authorized #{operation} task for order #{request.input.order}."
      ])

    state = apply(Sagents.State, :new!, [%{messages: [message]}])
    {:ok, agent, state}
  end

  def result(%{processed_content: mapped}), do: mapped

  defp tool(name, description, callback) do
    apply(LangChain.Function, :new!, [
      %{
        name: name,
        description: description,
        async: false,
        strict: true,
        parameters_schema: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false,
          "required" => []
        },
        parse_args: fn arguments ->
          if arguments == %{}, do: :ok, else: {:error, "This task tool accepts no arguments"}
        end,
        function: fn _arguments, _context -> callback.() end
      }
    ])
  end
end
