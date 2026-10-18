defmodule OrderDesk.RecordedInputTest do
  use ExUnit.Case
  import Plug.Test
  alias OrderDesk.BrowserServer

  setup do
    previous = Application.get_env(:order_desk, :recorded_input, false)
    on_exit(fn -> Application.put_env(:order_desk, :recorded_input, previous) end)
    :ok
  end

  defp get(path), do: BrowserServer.call(conn(:get, path), BrowserServer.init([]))

  test "recorded input is absent by default and cannot be enabled through a request" do
    Application.put_env(:order_desk, :recorded_input, false)
    page = get("/?recorded_input=1")
    assert page.status == 200
    refute page.resp_body =~ "Connect recorded audio"
    assert get("/dev/recorded-input.js").status == 404
    assert get("/dev/audio/draft.wav").status == 404
  end

  test "explicitly enabled controls use only the fixed audio fixtures" do
    Application.put_env(:order_desk, :recorded_input, true)
    assert get("/").resp_body =~ "Connect recorded audio"
    assert get("/dev/recorded-input.js").status == 200
    assert get("/dev/audio/private.wav").status == 404
    assert get("/dev/audio/runtime.exs").status == 404
  end

  test "the environment flag cannot enable recorded input in production" do
    previous = System.get_env("ORDER_DESK_RECORDED_INPUT")
    System.put_env("ORDER_DESK_RECORDED_INPUT", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("ORDER_DESK_RECORDED_INPUT", previous),
        else: System.delete_env("ORDER_DESK_RECORDED_INPUT")
    end)

    assert Config.Reader.read!("config/runtime.exs", env: :dev)[:order_desk][:recorded_input]
    refute Config.Reader.read!("config/runtime.exs", env: :prod)[:order_desk][:recorded_input]
  end
end
