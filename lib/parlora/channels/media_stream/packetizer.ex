defmodule Parlora.Channels.MediaStream.Packetizer do
  @moduledoc false
  alias Parlora.AudioFormat

  # Twilio's live playout advanced once per 20 ms media message. Aggregate the
  # provider's 10 ms frames before handing them to that remote playout boundary.
  @packet_bytes 160
  @flush_us 20_000

  def take(queue, now, minimum_bytes \\ 0)
  def take(%{bytes: 0}, _now, _minimum_bytes), do: :empty

  def take(queue, now, minimum_bytes) do
    {:value, first} = :queue.peek(queue.items)
    age = now - first.timestamp_us

    if queue.bytes < @packet_bytes and age < @flush_us do
      {:wait, max(1, div(@flush_us - age + 999, 1_000))}
    else
      {parts, rest} = consume(queue, min(@packet_bytes, queue.bytes), [])
      data = parts |> Enum.reverse() |> IO.iodata_to_binary()

      # Telnyx requires at least 20 ms per outbound message. Pad only a short
      # tail with PCMU silence; Twilio retains its validated unpadded behaviour.
      data = data <> :binary.copy(<<255>>, max(0, minimum_bytes - byte_size(data)))

      frame = %{
        first
        | data: data,
          duration_us: AudioFormat.duration_us(first.format, byte_size(data))
      }

      {:ready, frame, rest}
    end
  end

  defp consume(queue, 0, parts), do: {parts, queue}

  defp consume(queue, remaining, parts) do
    {{:value, frame}, items} = :queue.out(queue.items)
    count = min(remaining, byte_size(frame.data))
    <<part::binary-size(^count), tail::binary>> = frame.data

    items =
      if tail == <<>> do
        items
      else
        remainder = %{
          frame
          | data: tail,
            duration_us: AudioFormat.duration_us(frame.format, byte_size(tail))
        }

        :queue.in_r(remainder, items)
      end

    consume(%{queue | items: items, bytes: queue.bytes - count}, remaining - count, [part | parts])
  end
end
