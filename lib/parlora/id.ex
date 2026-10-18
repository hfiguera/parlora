defmodule Parlora.ID do
  @moduledoc false
  @spec new() :: String.t()
  def new, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
