defmodule Parlora.TestSupport.SagentsModel do
  @moduledoc false
  @behaviour LangChain.ChatModels.ChatModel
  alias LangChain.{Function, LangChainError, Message}
  alias LangChain.Message.ToolCall
  defstruct [:request, :observer, mode: :complete, callbacks: [], stream: false]

  @impl true
  def call(%{mode: :model_error}, _messages, _tools),
    do: {:error, %LangChainError{type: "fixture", message: "private-key-and-prompt"}}

  def call(%{mode: :no_tool}, _messages, _tools),
    do: {:ok, Message.new_assistant!("Unverified model answer")}

  def call(model, messages, _tools) do
    steps = Enum.count(messages, &(&1.role == :tool))
    name = if model.mode == :multi_step and steps == 0, do: "read", else: "finish"
    send(model.observer, {:model_call, model.request.id, steps, self()})

    {:ok,
     Message.new_assistant!(%{
       tool_calls: [
         ToolCall.new!(%{
           call_id: "call-#{steps}",
           name: name,
           arguments: %{},
           status: :complete
         })
       ]
     })}
  end

  @impl true
  def retry_on_fallback?(_error), do: false
  @impl true
  def serialize_config(_model), do: %{}
  @impl true
  def restore_from_map(_map), do: {:error, "Fixture is request scoped"}

  def options(observer, mode \\ :complete) do
    [
      agent: fn request -> build(request, observer, mode) end,
      completion_tool: "finish",
      max_runs: 3,
      result: fn terminal -> terminal.processed_content end
    ]
  end

  defp build(request, observer, mode) do
    finish =
      Function.new!(%{
        name: "finish",
        async: false,
        function: fn _arguments, _context ->
          wait(request, observer)

          if mode == :tool_error do
            {:error, "Controlled tool failure"}
          else
            facts = %{order: request.input.order}

            {:ok, "Authoritative result",
             %{
               status: :completed,
               facts: facts,
               summary: "Order #{request.input.order} arrives tomorrow"
             }}
          end
        end
      })

    read =
      Function.new!(%{
        name: "read",
        async: false,
        function: fn _arguments, _context ->
          send(observer, {:read_tool, request.id})
          {:ok, "Read succeeded"}
        end
      })

    agent =
      Sagents.Agent.new!(
        %{
          model: %__MODULE__{request: request, observer: observer, mode: mode},
          tools: [read, finish],
          base_system_prompt: "Use application tools",
          middleware: []
        },
        replace_default_middleware: true
      )

    state = Sagents.State.new!(%{messages: [Message.new_user!("Look up order")]})
    {:ok, agent, state}
  end

  defp wait(request, observer) do
    if request.input[:gate] do
      send(observer, {:lookup_waiting, request.input.order, self()})

      receive do
        :finish -> :ok
      after
        5_000 -> raise "Fixture not released"
      end
    else
      Process.sleep(Map.get(request.input, :delay_ms, 0))
    end
  end
end
