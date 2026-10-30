defmodule Parlora.TestSupport.PhonicPeer do
  @moduledoc false
  def init(owner) do
    send(owner, {:phonic_peer, self()})
    {:ok, owner}
  end

  def handle_in({json, _metadata}, owner) do
    send(owner, {:phonic_command, JSON.decode!(json)})
    {:ok, owner}
  end

  def handle_info({:raw_json, bytes}, owner), do: {:push, {:text, bytes}, owner}
  def handle_info({:phonic_event, event}, owner), do: {:push, {:text, JSON.encode!(event)}, owner}
  def handle_info(:disconnect, owner), do: {:stop, :normal, owner}
end

defmodule Parlora.TestSupport.PhonicPeer.Route do
  @moduledoc false
  def init(owner), do: owner

  def call(conn, owner),
    do:
      conn
      |> WebSockAdapter.upgrade(Parlora.TestSupport.PhonicPeer, owner, [])
      |> Plug.Conn.halt()
end
