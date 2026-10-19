defmodule OrderDesk.PhoneReviewTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  alias OrderDesk.{BrowserServer, BrowserGate, Store}

  setup do
    previous =
      Map.new(
        [
          :twilio_review_actor,
          :phone_review_actor,
          :browser_origin,
          :browser_offline,
          :cookie_secret
        ],
        &{&1, Application.get_env(:order_desk, &1)}
      )

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:order_desk, key),
          else: Application.put_env(:order_desk, key, value)
      end
    end)

    :ok
  end

  test "root review adopts phone identity and confirmation notifies the matching live session" do
    Application.delete_env(:order_desk, :twilio_review_actor)
    old_page = route(conn(:get, "/api/orders"))
    old_csrf = JSON.decode!(old_page.resp_body)["csrf"]
    [{name, cookie}] = Map.to_list(old_page.resp_cookies)
    actor = Parlora.ID.new()
    Application.put_env(:order_desk, :twilio_review_actor, actor)
    Application.put_env(:order_desk, :browser_origin, "http://localhost:4101")
    Application.put_env(:order_desk, :browser_offline, true)

    {:ok, session} =
      BrowserGate.start_session({Parlora.Channels.LocalAudio, device: :synthetic}, actor)

    on_exit(fn -> close_session(session) end)
    assert_receive {:scripted_provider, provider}
    OrderDesk.ScriptedProvider.audio(provider, false)
    assert_receive {:parlora_event, %{source: :session, type: :ready}}, 1_000
    id = Parlora.ID.new()
    {:ok, _} = Store.propose(actor, "825", "Leave it at reception", id)
    # Direct root navigation with an existing browser cookie must adopt the phone actor.
    page = conn(:get, "/") |> put_req_cookie(name, cookie.value) |> route()
    assert get_session(page, :actor) == actor
    csrf = get_session(page, :csrf)
    refute csrf == old_csrf
    [{name, cookie}] = Map.to_list(page.resp_cookies)
    dashboard = conn(:get, "/api/orders") |> put_req_cookie(name, cookie.value) |> route()
    assert Enum.any?(JSON.decode!(dashboard.resp_body)["proposals"], &(&1["id"] == id))

    response =
      conn(:post, "/api/proposals/#{id}/confirm", "{}")
      |> put_req_cookie(name, cookie.value)
      |> put_req_header("origin", "http://localhost:4101")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-csrf-token", csrf)
      |> route()

    assert response.status == 200
    assert_receive {:context, update}, 2_000
    assert update.content =~ "confirmed and saved delivery instructions for order 825"
    assert {:ok, %{instructions: "Leave it at reception"}} = Store.order("825")
  end

  test "normal browser mode retains separate identities and has no phone-review route" do
    Application.delete_env(:order_desk, :twilio_review_actor)
    first = route(conn(:get, "/"))
    second = route(conn(:get, "/"))
    refute get_session(first, :actor) == get_session(second, :actor)
    assert route(conn(:get, "/phone-review")).status == 404
  end

  test "browser and phone listeners keep independent sessions in a shared cookie jar" do
    actor = Parlora.ID.new()
    id = Parlora.ID.new()
    {:ok, _} = Store.propose(actor, "825", "Leave it at the side door", id)
    browser_secret = Base.encode64(:crypto.strong_rand_bytes(64))
    phone_secret = Base.encode64(:crypto.strong_rand_bytes(64))

    Application.put_env(:order_desk, :browser_origin, "http://localhost:4201")
    Application.put_env(:order_desk, :phone_review_actor, actor)
    Application.put_env(:order_desk, :cookie_secret, phone_secret)
    phone = route(conn(:get, "/api/orders"))
    csrf = JSON.decode!(phone.resp_body)["csrf"]
    jar = phone.resp_cookies

    Application.put_env(:order_desk, :browser_origin, "http://localhost:4000")
    Application.delete_env(:order_desk, :phone_review_actor)
    Application.put_env(:order_desk, :cookie_secret, browser_secret)
    browser = route(with_cookies(conn(:get, "/api/orders"), jar))
    browser_actor = get_session(browser, :actor)
    jar = Map.merge(jar, browser.resp_cookies)

    Application.put_env(:order_desk, :browser_origin, "http://localhost:4201")
    Application.put_env(:order_desk, :phone_review_actor, actor)
    Application.put_env(:order_desk, :cookie_secret, phone_secret)

    confirm =
      conn(:post, "/api/proposals/#{id}/confirm", "{}")
      |> with_cookies(jar)
      |> put_req_header("origin", "http://localhost:4201")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-csrf-token", csrf)

    assert route(put_req_header(confirm, "x-csrf-token", "wrong")).status == 403
    assert route(put_req_header(confirm, "origin", "http://localhost:4000")).status == 403
    response = route(confirm)
    assert response.status == 200
    assert get_session(response, :actor) == actor
    assert JSON.decode!(response.resp_body)["result"]["duplicate"] == false
    assert route(confirm).status == 200
    assert {:ok, %{instructions: "Leave it at the side door"}} = Store.order("825")

    Application.put_env(:order_desk, :browser_origin, "http://localhost:4000")
    Application.delete_env(:order_desk, :phone_review_actor)
    Application.put_env(:order_desk, :cookie_secret, browser_secret)
    next = route(with_cookies(conn(:get, "/api/orders"), Map.merge(jar, response.resp_cookies)))
    assert get_session(next, :actor) == browser_actor
    assert JSON.decode!(next.resp_body)["csrf"] == JSON.decode!(browser.resp_body)["csrf"]
  end

  defp with_cookies(conn, cookies) do
    Enum.reduce(cookies, conn, fn {name, cookie}, conn ->
      put_req_cookie(conn, name, cookie.value)
    end)
  end

  defp close_session(session) do
    ref = Process.monitor(session)
    if Process.alive?(session), do: Parlora.close(session, :cancel)

    receive do
      {:DOWN, ^ref, :process, ^session, _reason} -> :ok
    after
      5_000 -> flunk("Phone review session did not close")
    end

    await_gate_empty(100)
  end

  defp await_gate_empty(0), do: flunk("Phone review session remained admitted")

  defp await_gate_empty(attempts) do
    if BrowserGate.count() > 0 do
      Process.sleep(10)
      await_gate_empty(attempts - 1)
    end
  end

  defp route(conn), do: BrowserServer.call(conn, BrowserServer.init([]))
end
