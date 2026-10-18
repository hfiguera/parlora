defmodule Parlora.ProviderClient do
  @moduledoc false

  defmacro __using__(options) do
    protocol = Keyword.fetch!(options, :protocol)

    quote do
      use Parlora.AdapterClient
      @behaviour Parlora.Provider

      @impl true
      def start_link(init, options) do
        with {:ok, startup} <- unquote(protocol).start(options, init.audio_format) do
          GenServer.start_link(__MODULE__, {init, options, startup})
        end
      end

      @impl true
      def append_context(pid, update), do: Parlora.Adapter.call(pid, {:append, update})

      @impl true
      def output_buffer_status(pid), do: Parlora.Adapter.call(pid, :output_buffer_status)

      @impl true
      def arm_output_ready(pid, reader, reference),
        do: Parlora.Adapter.call(pid, {:arm_output_ready, reader, reference})
    end
  end
end
