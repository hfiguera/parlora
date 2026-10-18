defmodule Parlora.AudioQueue do
  @moduledoc false
  alias Parlora.{AudioFrame, Error}

  @type t :: %__MODULE__{}
  defstruct items: :queue.new(), bytes: 0, capacity: 9_600

  @spec push(t(), AudioFrame.t()) :: {:ok, t()} | {:error, Error.t()}
  def push(queue, %AudioFrame{data: data} = frame) do
    bytes = queue.bytes + byte_size(data)

    if bytes <= queue.capacity do
      {:ok, %{queue | items: :queue.in(frame, queue.items), bytes: bytes}}
    else
      Error.tuple(:backpressure, "Audio queue is full")
    end
  end

  @spec pop(t(), pos_integer()) :: {[AudioFrame.t()], t()}
  def pop(queue, budget), do: drain(queue, budget, [])

  @spec clear(t()) :: t()
  def clear(queue), do: %{queue | items: :queue.new(), bytes: 0}

  # Network pacing may require fewer bytes than an admitted frame. Keep the
  # remainder at the front so a larger valid frame cannot block transmission.
  def take_bytes(queue, budget) do
    case :queue.out(queue.items) do
      {{:value, frame}, rest} when budget > 0 ->
        size = min(byte_size(frame.data), budget)
        <<head::binary-size(^size), tail::binary>> = frame.data
        items = if tail == <<>>, do: rest, else: :queue.in_r(%{frame | data: tail}, rest)

        {more, next} =
          take_bytes(%{queue | items: items, bytes: queue.bytes - size}, budget - size)

        {head <> more, next}

      _empty ->
        {<<>>, queue}
    end
  end

  def reply_read(state, budget)
      when is_integer(budget) and budget >= state.init.limits.max_frame_bytes do
    {frames, queue} = pop(state.inbound, budget)
    {:reply, {:ok, frames}, %{state | inbound: queue}}
  end

  def reply_read(state, _budget),
    do:
      {:reply, Error.tuple(:invalid_argument, "Read budget is below the maximum frame size"),
       state}

  defp drain(queue, budget, acc) do
    case :queue.out(queue.items) do
      {{:value, frame}, rest} when byte_size(frame.data) <= budget ->
        size = byte_size(frame.data)
        drain(%{queue | items: rest, bytes: queue.bytes - size}, budget - size, [frame | acc])

      _empty_or_over_budget ->
        {Enum.reverse(acc), queue}
    end
  end
end
