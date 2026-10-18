defmodule Parlora.Providers.Gemini.Connection do
  @moduledoc false
  alias Parlora.Provider.WebSocketConnection
  alias Parlora.Providers.Gemini.Protocol

  def connect(key, version, endpoint \\ {:https, "generativelanguage.googleapis.com", 443}),
    do: WebSocketConnection.connect(endpoint, Protocol.path(version), [{"x-goog-api-key", key}])

  defdelegate send(socket, frame), to: WebSocketConnection
  defdelegate receive(socket, message), to: WebSocketConnection
  defdelegate close(socket), to: WebSocketConnection
end
