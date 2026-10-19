defmodule OrderDesk.ApplicationFlowTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  alias OrderDesk.BrowserServer

  test "policy, Jido and SQLite handle correction, items and draft without voice writes" do
    classify = fn state ->
      cond do
        state.caller_history =~ "leave it at reception" ->
          {:ok, %{intent: "delivery", order: "124"}}

        state.caller_history =~ "What items" ->
          {:ok, %{intent: "items", order: "124"}}

        state.caller_history =~ "Actually" ->
          {:ok, %{intent: "status", order: "124"}}

        true ->
          {:ok, %{intent: "status", order: "123"}}
      end
    end

    assert %{correction: true, items: true, draft_only: true, refusal_did_not_write: true} =
             OrderDesk.AppSmoke.run(classify: classify)

    await_cleanup()
  end

  test "browser mutations require origin and CSRF; explicit Jido confirmation is idempotent" do
    Application.put_env(:order_desk, :browser_origin, "http://localhost:4000")
    on_exit(fn -> Application.delete_env(:order_desk, :browser_origin) end)
    response = conn(:get, "/api/orders") |> route()
    %{"csrf" => csrf} = JSON.decode!(response.resp_body)
    [{cookie_name, cookie}] = Map.to_list(response.resp_cookies)
    base = conn(:post, "/api/proposals") |> put_req_cookie(cookie_name, cookie.value)
    assert %{status: 403} = base |> route()
    id = Parlora.ID.new()
    body = %{id: id, order: "825", instructions: "Leave it at reception"}
    assert %{status: 403} = request(response, "/api/proposals", body, "wrong")
    assert %{status: 200} = request(response, "/api/proposals", body, csrf)
    assert {:ok, before_order} = OrderDesk.Store.order("825")

    assert %{status: 200, resp_body: first} =
             request(response, "/api/proposals/#{id}/confirm", %{}, csrf)

    assert JSON.decode!(first)["result"]["duplicate"] == false

    assert %{status: 200, resp_body: duplicate} =
             request(response, "/api/proposals/#{id}/confirm", %{}, csrf)

    assert JSON.decode!(duplicate)["result"]["duplicate"] == true
    assert {:ok, after_order} = OrderDesk.Store.order("825")
    assert after_order.version == before_order.version + 1
    assert after_order.instructions == body.instructions
    stranger = conn(:get, "/api/orders") |> route()
    stranger_csrf = JSON.decode!(stranger.resp_body)["csrf"]
    assert %{status: 409} = request(stranger, "/api/proposals/#{id}/confirm", %{}, stranger_csrf)
  end

  defp request(session, path, body, csrf) do
    [{name, cookie}] = Map.to_list(session.resp_cookies)

    conn(:post, path, JSON.encode!(body))
    |> put_req_cookie(name, cookie.value)
    |> put_req_header("origin", "http://localhost:4000")
    |> put_req_header("x-csrf-token", csrf)
    |> put_req_header("content-type", "application/json")
    |> route()
  end

  defp route(conn), do: BrowserServer.call(conn, BrowserServer.init([]))
  defp await_cleanup(attempts \\ 100)
  defp await_cleanup(0), do: flunk("Session did not close")

  defp await_cleanup(attempts) do
    if DynamicSupervisor.count_children(Parlora.Sessions).active > 0 do
      Process.sleep(10)
      await_cleanup(attempts - 1)
    end
  end
end
