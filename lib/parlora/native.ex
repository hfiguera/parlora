defmodule Parlora.Native do
  @moduledoc false
  alias Parlora.Error

  # Rustler Error::Term returns {:error, reason}; it does not raise an exception.
  # Normalize it before matching success values or reporting control completion.
  def unwrap!({:error, _reason}), do: raise(ErlangError, original: :native_operation_failed)
  def unwrap!(value), do: value

  def call(function) do
    {:ok, function.()}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error,
       Error.new(:adapter_failed, "Native audio operation failed", %{exception: error.__struct__})}
  end
end
