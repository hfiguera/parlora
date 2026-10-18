defmodule Parlora.OutputSpace do
  @moduledoc false

  # One notification per arm. Queue consumption owns this boundary, and the
  # epoch prevents an old writer wakeup surviving a clear or suppression.
  def arm(state, writer, reference, bytes, epoch) do
    if epoch == state.epoch and not state.suppressed do
      notify(%{state | output_waiter: {writer, reference, bytes, epoch}})
    else
      state
    end
  end

  def notify(%{output_waiter: {writer, reference, bytes, epoch}, epoch: epoch} = state) do
    if not state.suppressed and state.outbound.capacity - state.outbound.bytes >= bytes do
      send(writer, {:parlora_output_space, self(), reference})
      %{state | output_waiter: nil}
    else
      state
    end
  end

  def notify(state), do: state
end
