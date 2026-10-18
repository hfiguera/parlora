defmodule Parlora.AdapterBehaviour do
  @moduledoc false

  defmacro __using__(options) do
    capabilities = Keyword.fetch!(options, :capabilities)

    quote do
      @callback start_link(Parlora.AdapterInit.t(), keyword()) ::
                  {:ok, pid()} | {:error, Parlora.Error.t()}
      @callback capabilities(pid()) ::
                  {:ok, unquote(capabilities).t()} | {:error, Parlora.Error.t()}
      @callback close(pid(), String.t(), term()) :: :ok | {:error, Parlora.Error.t()}
    end
  end
end
