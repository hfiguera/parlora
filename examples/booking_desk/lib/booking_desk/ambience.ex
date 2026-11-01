defmodule BookingDesk.Ambience do
  @moduledoc "Optional deterministic background PCM on the replay caller's live input."
  defstruct [:pcm, :info, cursor: 0, clipped_samples: 0, mixed_ticks: 0]

  def prepare!(nil, _directory), do: nil

  def prepare!(manifest, directory) do
    info = manifest |> File.read!() |> JSON.decode!()
    pcm = manifest |> Path.dirname() |> Path.join(info["pcm_file"]) |> File.read!()

    unless info["sample_rate"] == 24_000 and info["channels"] == 1 and
             info["encoding"] == "pcm_s16le" and byte_size(pcm) >= 480 and
             rem(byte_size(pcm), 480) == 0 and byte_size(pcm) <= 4_800_000 and
             hash(pcm) == info["pcm_sha256"],
           do: raise(ArgumentError, "Expected bounded, hash-verified mono 24kHz ambience PCM")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    File.write!(Path.join(directory, "ambience.pcm"), pcm, [:exclusive])
    File.chmod!(Path.join(directory, "ambience.pcm"), 0o600)
    %__MODULE__{pcm: pcm, info: info}
  end

  def mix(nil, voice), do: {voice, nil}

  def mix(%__MODULE__{} = state, voice) do
    length = byte_size(state.pcm)
    count = byte_size(voice)
    tail = binary_part(state.pcm, state.cursor, min(count, length - state.cursor))
    noise = tail <> binary_part(state.pcm, 0, count - byte_size(tail))

    {mixed, clipped} = add(voice, noise, [], 0)

    {mixed,
     %{
       state
       | cursor: rem(state.cursor + count, length),
         clipped_samples: state.clipped_samples + clipped,
         mixed_ticks: state.mixed_ticks + 1
     }}
  end

  def info(nil), do: nil

  def info(state),
    do:
      Map.merge(state.info, %{
        "clipped_samples" => state.clipped_samples,
        "mixed_ticks" => state.mixed_ticks,
        "input_mix" => "caller_pcm_plus_continuous_ambience"
      })

  defp add(<<>>, <<>>, acc, clipped),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), clipped}

  defp add(
         <<v::signed-little-16, voice::binary>>,
         <<n::signed-little-16, noise::binary>>,
         acc,
         clipped
       ) do
    sum = v + n
    value = max(-32_768, min(32_767, sum))

    add(
      voice,
      noise,
      [<<value::signed-little-16>> | acc],
      clipped + if(sum == value, do: 0, else: 1)
    )
  end

  defp hash(pcm), do: :crypto.hash(:sha256, pcm) |> Base.encode16(case: :lower)
end
