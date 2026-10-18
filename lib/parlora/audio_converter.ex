defmodule Parlora.AudioConverter do
  @moduledoc false
  alias Parlora.Native
  alias Parlora.Native.Resampler

  defstruct [:resource, :chunk_bytes, :output_channels, pending: <<>>]

  def new(input_rate, output_rate, input_channels, output_channels) do
    chunk = div(input_rate, 100)

    {:ok, resource} =
      Resampler.new(input_rate, output_rate, input_channels, output_channels, chunk)
      |> Native.unwrap!()

    %__MODULE__{
      resource: resource,
      chunk_bytes: chunk * input_channels * 2,
      output_channels: output_channels
    }
  end

  def convert(converter, bytes) do
    process(%{converter | pending: converter.pending <> bytes}, [])
  end

  def reset(converter) do
    :ok = Resampler.reset(converter.resource) |> Native.unwrap!()
    %{converter | pending: <<>>}
  end

  def close(converter), do: Resampler.close(converter.resource) |> Native.unwrap!()

  defp process(%{pending: pending, chunk_bytes: size} = converter, acc)
       when byte_size(pending) >= size do
    <<block::binary-size(^size), rest::binary>> = pending
    {:ok, output, _frames} = Resampler.process(converter.resource, block) |> Native.unwrap!()
    process(%{converter | pending: rest}, [output | acc])
  end

  defp process(converter, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), converter}
end
