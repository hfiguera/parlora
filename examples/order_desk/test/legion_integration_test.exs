if Code.ensure_loaded?(Legion) do
  defmodule OrderDesk.LegionIntegrationTest do
    use ExUnit.Case
    import Plug.Test
    import Plug.Conn
    alias Parlora.{AdapterInit, BackendRequest, Event, Limits}
    alias Parlora.Backends.Legion, as: Backend
    alias OrderDesk.{BrowserServer, Store}

    setup do
      Application.put_env(:req_llm, :openai_api_key, "fixture-only")
      Application.put_env(:order_desk, :browser_origin, "http://localhost:4000")
      on_exit(fn -> Application.delete_env(:order_desk, :browser_origin) end)
      :ok
    end

    test "an explicit backend bypasses Legion selection without requiring a text credential" do
      Application.put_env(:order_desk, :backend, :legion)
      on_exit(fn -> Application.put_env(:order_desk, :backend, :jido) end)

      override =
        {Parlora.Backends.Jido,
         agent: OrderDesk.OrderAgent,
         agent_options: [jido: OrderDesk.Jido],
         result: &OrderDesk.map_result/1}

      {:ok, session} =
        OrderDesk.start_session(
          {Parlora.Channels.LocalAudio, device: :synthetic},
          {OrderDesk.ScriptedProvider, observer: self()},
          backend: override
        )

      assert :ok = Parlora.close(session)
    end

    test "real Lua reads and computes overview, and native verification rejects invented totals" do
      code =
        "local row = Tool.run('read_items'); Tool.run('read_status'); local count = 0; for _, item in ipairs(row.data.items) do count = count + item.quantity end; Tool.complete({item_count = count})"

      result = execute(%{order: "124", operation: "overview"}, code)
      {:ok, order} = Store.order("124")
      assert result.facts.item_count == Enum.sum_by(order.items, & &1["quantity"])
      assert result.summary =~ "out for delivery" and result.summary =~ "contains"

      backend =
        start_backend(
          "Tool.run('read_status'); Tool.run('read_items'); Tool.complete({item_count = 999})"
        )

      assert :ok = Backend.submit(backend, request(%{order: "124", operation: "overview"}))
      assert_receive {:parlora_event, %Event{type: :request_uncertain}}, 5_000
    end

    test "ordinary tasks omit compound instructions, and corrected status runs through real Lua" do
      for operation <- ["status", "items", "instructions", "delivery"] do
        execution =
          OrderDesk.LegionAgent.build(request(%{order: "124", operation: operation}), %{
            model_fixture: :unused
          })

        refute execution.task =~ "item_count"
        refute execution.task =~ "read_items"
        refute execution.task =~ "overview"
        assert execution.task =~ "Tool.complete() with no arguments"
      end

      # The live failure attempted this calculation on a status response, whose
      # native data has no items; a second attempt was rejected for supplying a count.
      failed =
        start_backend(
          "local r = Tool.run('lookup'); for _, item in ipairs(r.data.items) do end; Tool.complete({item_count = 0})"
        )

      assert :ok = Backend.submit(failed, request(%{order: "124", operation: "status"}))
      assert_receive {:parlora_event, %Event{type: :request_uncertain}}, 5_000

      backend = start_backend("local status = Tool.run('lookup'); Tool.complete(); return status")
      first = request(%{order: "123", operation: "status"})
      second = %{request(%{order: "124", operation: "status"}) | task_revision: 2}
      assert :ok = Backend.submit(backend, first)
      assert :ok = Backend.submit(backend, second)

      assert_receive {:parlora_event,
                      %Event{
                        type: :request_completed,
                        request_id: first_id,
                        payload: %{facts: %{order: "123"}}
                      }},
                     5_000

      assert first_id == first.id

      assert_receive {:parlora_event,
                      %Event{type: :request_completed, request_id: second_id, payload: result}},
                     5_000

      assert second_id == second.id
      assert result.task_revision == 2 and result.facts.order == "124"
      assert result.summary =~ "out for delivery"
    end

    test "Lua cannot broaden order, actor, instruction or save authority" do
      actor = Parlora.ID.new()
      input = %{order: "825", operation: "delivery", actor: actor, instructions: "Reception"}
      backend = start_backend("Tool.run('save'); Tool.complete()")
      assert :ok = Backend.submit(backend, request(input))
      assert_receive {:parlora_event, %Event{type: :request_uncertain}}, 5_000
      assert Store.dashboard(actor).proposals == []
      backend = start_backend("Tool.run('lookup', '123', 'Invented'); Tool.complete()")
      assert :ok = Backend.submit(backend, request(input))
      assert_receive {:parlora_event, %Event{type: :request_uncertain}}, 5_000
      assert Store.dashboard(actor).proposals == []
    end

    test "repeated draft execution is cached; only authenticated browser confirmation saves once" do
      page = conn(:get, "/api/orders") |> route()
      dashboard = Jason.decode!(page.resp_body)
      actor = get_session(page, :actor)
      {:ok, before_order} = Store.order("825")

      result =
        execute(
          %{order: "825", operation: "delivery", actor: actor, instructions: "Reception"},
          "pcall(Tool.complete); for i = 1,3 do Tool.run('lookup') end; Tool.complete()"
        )

      assert result.summary =~ "Nothing has been changed"
      assert {:ok, ^before_order} = Store.order("825")
      [proposal] = Store.dashboard(actor).proposals
      path = "/api/proposals/#{proposal.id}/confirm"
      assert %{status: 403} = confirmation(page, path, "wrong")
      assert %{status: 200, resp_body: first} = confirmation(page, path, dashboard["csrf"])
      assert Jason.decode!(first)["result"]["duplicate"] == false
      assert %{status: 200, resp_body: second} = confirmation(page, path, dashboard["csrf"])
      assert Jason.decode!(second)["result"]["duplicate"] == true
      assert {:ok, after_order} = Store.order("825")
      assert after_order.version == before_order.version + 1
      assert after_order.instructions == "Reception"
    end

    defp confirmation(page, path, csrf) do
      [{name, cookie}] = Map.to_list(page.resp_cookies)

      conn(:post, path, "{}")
      |> put_req_cookie(name, cookie.value)
      |> put_req_header("origin", "http://localhost:4000")
      |> put_req_header("x-csrf-token", csrf)
      |> put_req_header("content-type", "application/json")
      |> route()
    end

    defp route(conn), do: BrowserServer.call(conn, BrowserServer.init([]))

    defp execute(input, code) do
      backend = start_backend(code)
      assert :ok = Backend.submit(backend, request(input))
      assert_receive {:parlora_event, %Event{type: :request_completed, payload: result}}, 5_000
      result
    end

    defp start_backend(code) do
      model =
        {:openai, "gpt-6-luna",
         reasoning_effort: :none,
         max_tokens: 1_000,
         total_timeout: :infinity,
         req_http_options: [
           retry: false,
           plug: fn conn ->
             {:ok, _body, conn} = Plug.Conn.read_body(conn)
             action = %{action: "eval_and_complete", code: code, result: ""}

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
         ]}

      init = %AdapterInit{
        session_id: "fixture",
        adapter_id: "backend",
        generation: 0,
        event_sink: self(),
        limits: %Limits{job_timeout_ms: 5_000}
      }

      {:ok, pid} =
        Backend.start_link(init,
          max_retries: 0,
          execution: &OrderDesk.LegionAgent.build(&1, %{model_fixture: model})
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
  defmodule OrderDesk.WithoutLegionTest do
    use ExUnit.Case

    test "absent optional framework reports unsupported without installing its stack" do
      init = %Parlora.AdapterInit{
        session_id: "optional",
        adapter_id: "backend",
        generation: 0,
        event_sink: self(),
        limits: %Parlora.Limits{}
      }

      assert {:error, %{code: :unsupported}} = Parlora.Backends.Legion.start_link(init, [])
      refute Code.ensure_loaded?(Lua)
      refute Code.ensure_loaded?(ReqLLM)
      refute Code.ensure_loaded?(Vault)
    end
  end
end
