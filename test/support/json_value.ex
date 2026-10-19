defmodule Parlora.TestSupport.JSONValue do
  @moduledoc false
  @derive {JSON.Encoder, only: [:value]}
  defstruct [:value, :private]
end
