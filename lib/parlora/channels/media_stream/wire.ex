defmodule Parlora.Channels.MediaStream.Wire do
  @moduledoc false
  alias Parlora.Error

  def number(raw) when is_binary(raw) and byte_size(raw) in 1..16 do
    case Integer.parse(raw) do
      {value, ""} when value >= 0 -> {:ok, value}
      _invalid -> invalid()
    end
  end

  def number(_raw), do: invalid()

  defp invalid,
    do:
      {:error,
       Error.new(:invalid_argument, "Invalid media stream number", %{reason: :invalid_number})}
end
