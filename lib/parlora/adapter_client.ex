defmodule Parlora.AdapterClient do
  @moduledoc false

  defmacro __using__(options) do
    output_space = Keyword.get(options, :output_space, false)

    quote do
      @impl true
      def capabilities(pid), do: Parlora.Adapter.call(pid, :capabilities)
      @impl true
      def read_audio(pid, budget), do: Parlora.Adapter.call(pid, {:read, budget})
      @impl true
      def write_audio(pid, frame), do: Parlora.Adapter.call(pid, {:write, frame})
      @impl true
      def control(pid, id, control), do: Parlora.Adapter.call(pid, {:control, id, control})
      @impl true
      def close(pid, id, reason), do: Parlora.Adapter.call(pid, {:close, id, reason})

      if unquote(output_space) do
        @impl true
        def arm_output_space(pid, writer, reference, bytes, epoch),
          do: Parlora.Adapter.call(pid, {:arm_output_space, writer, reference, bytes, epoch})
      end
    end
  end
end
