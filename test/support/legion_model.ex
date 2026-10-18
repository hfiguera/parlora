defmodule Parlora.TestSupport.LegionModel do
  @moduledoc false

  def model(observer, code, id \\ "fixture") do
    {:openai, "gpt-6-luna",
     reasoning_effort: :none,
     max_tokens: 1_000,
     receive_timeout: 1_000,
     total_timeout: :infinity,
     req_http_options: [
       retry: false,
       plug: fn conn ->
         step = Process.get(:legion_fixture_step, 0)
         Process.put(:legion_fixture_step, step + 1)
         send(observer, {:legion_model_call, id, step, self()})
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(observer, {:legion_wire, id, Jason.decode!(body)})
         code = if is_function(code, 1), do: code.(step), else: code

         if code == :error do
           conn
           |> Plug.Conn.put_status(400)
           |> Req.Test.json(%{error: %{message: "private-key-and-prompt"}})
         else
           action =
             case code do
               {:continue, script} ->
                 %{"action" => "eval_and_continue", "code" => script, "result" => ""}

               script ->
                 %{"action" => "eval_and_complete", "code" => script, "result" => ""}
             end

           Req.Test.json(conn, %{
             id: "resp_fixture",
             object: "response",
             status: "completed",
             model: "gpt-6-luna",
             output: [
               %{
                 type: "function_call",
                 id: "fc_fixture",
                 call_id: "call_fixture",
                 name: "structured_output",
                 arguments: Jason.encode!(action)
               }
             ],
             usage: %{input_tokens: 12, output_tokens: 8, total_tokens: 20}
           })
         end
       end
     ]}
  end

  def options(observer, mode \\ :complete) do
    [execution: fn request -> build(request, observer, mode) end, max_retries: 0]
  end

  defp build(request, observer, mode) do
    %{
      model: model(observer, script(mode), request.id),
      task: "Check admitted order",
      operations: %{"lookup" => operation(request, observer, mode)},
      result: fn results ->
        facts = results["lookup"]

        %{
          status: if(mode == :native_failed, do: :failed, else: :completed),
          facts: facts,
          summary:
            if(mode == :oversized,
              do: String.duplicate("x", 70_000),
              else: "Order #{facts.order} arrives tomorrow"
            )
        }
      end
    }
  end

  defp operation(request, observer, mode) do
    fn ->
      send(observer, {:native_operation, request.id, self()})

      if request.input[:gate] do
        send(observer, {:lookup_waiting, request.input.order, self()})

        receive do
          :finish -> :ok
        after
          5_000 -> raise "Fixture not released"
        end
      end

      if mode == :tool_error, do: raise("private-key-and-prompt")
      {:ok, %{order: request.input.order}}
    end
  end

  defp script(:mutated_native),
    do: "local row = Tool.run('lookup'); row.order = '999'; Tool.complete(); return row"

  defp script(:model_error), do: :error
  defp script(:fake), do: "return 'Order 999 saved'"
  defp script(:continue), do: {:continue, "Tool.run('lookup'); return 'continuing'"}
  defp script(:invalid_code), do: "this is not lua!!!"
  defp script(:native_without_complete), do: "return Tool.run('lookup')"
  defp script(:missing), do: "Tool.complete(); return 'done'"
  defp script(:oversized), do: "Tool.run('lookup'); Tool.complete()"
  defp script(:cpu), do: "while true do end"
  defp script(:heap), do: "return string.rep('x', 64000000)"
  defp script(:unauthorized), do: "Tool.run('other-order'); Tool.complete()"
  defp script(:tool_metadata), do: "Tool.summary(); Tool.run('lookup'); Tool.complete()"

  defp script(:help),
    do:
      "local docs = Help.help(Tool); assert(type(docs) == 'string'); Tool.run('lookup'); Tool.complete()"

  defp script(:repeat), do: "for i=1,5 do Tool.run('lookup') end; Tool.complete()"

  defp script(:multi_step) do
    fn
      0 -> {:continue, "Tool.run('lookup'); return 'continue'"}
      _step -> "Tool.run('lookup'); Tool.complete()"
    end
  end

  defp script(_mode),
    do: "local row = Tool.run('lookup'); Tool.complete(); return row.order"
end
