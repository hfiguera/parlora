defmodule Parlora.Error do
  @moduledoc "A sanitized failure at a Parlora boundary."
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
  defexception [:code, :message, details: %{}]

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{}),
    do: %__MODULE__{code: code, message: message, details: details}

  @spec tuple(atom(), String.t(), map()) :: {:error, t()}
  def tuple(code, message, details \\ %{}), do: {:error, new(code, message, details)}
end
