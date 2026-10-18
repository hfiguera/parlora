Code.require_file("../validation/playout-hardening-20261003/timeline.exs", __DIR__)
Code.require_file("support/audio_benchmark/socket.ex", __DIR__)

defmodule Parlora.Validation.AudioRouter do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/health" do
    count = Agent.get(Parlora.Validation.AudioConnections, &MapSet.size/1)
    send_resp(conn, 200, Jason.encode!(%{active: count}))
  end

  get "/socket" do
    options = Application.fetch_env!(:parlora, :audio_benchmark)
    conn = fetch_query_params(conn)

    names = %{
      "steady" => :steady,
      "jitter" => :jitter,
      "burst" => :burst,
      "variable" => :variable
    }

    scenario = Map.fetch!(names, Map.get(conn.query_params, "scenario", "steady"))
    options = Keyword.put(options, :scenario, scenario)

    conn
    |> WebSockAdapter.upgrade(Parlora.Validation.AudioSocket, options,
      timeout: 60_000,
      max_frame_size: 65_536
    )
    |> halt()
  end

  get "/reference.wav" do
    options = Application.fetch_env!(:parlora, :audio_benchmark)

    pcm =
      options[:reference_pcm] ||
        Parlora.TestSupport.AudioBenchmark.Signal.pcm(options[:duration_ms])

    conn
    |> put_resp_content_type("audio/wav")
    |> send_resp(200, Parlora.TestSupport.AudioBenchmark.Signal.wav(pcm))
  end

  get "/" do
    conn |> put_resp_content_type("text/html") |> send_file(200, "validation/audio/receiver.html")
  end

  get "/receiver.js" do
    conn
    |> put_resp_content_type("text/javascript")
    |> send_file(200, "validation/audio/receiver.js")
  end

  get "/capture.js" do
    conn
    |> put_resp_content_type("text/javascript")
    |> send_file(200, "validation/audio/capture.js")
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end

scenario =
  case System.get_env("AUDIO_SCENARIO", "steady") do
    "steady" -> :steady
    "jitter" -> :jitter
    "variable" -> :variable
    "burst" -> :burst
    other -> raise "Unsupported receiver scenario: #{other}"
  end

seconds = String.to_integer(System.get_env("AUDIO_SECONDS", "10"))
unless seconds in 3..300, do: raise("AUDIO_SECONDS must be 3..300")
reference = if path = System.get_env("AUDIO_REFERENCE_PCM"), do: File.read!(path)
trace_directory = System.get_env("AUDIO_TRACE_DIRECTORY")
if trace_directory, do: File.mkdir_p!(trace_directory)

arrivals =
  if path = System.get_env("AUDIO_ARRIVAL_SCHEDULE"),
    do: path |> File.read!() |> Jason.decode!() |> Map.fetch!("arrivals")

if arrivals &&
     (reference == nil or Enum.sum(Enum.map(arrivals, & &1["bytes"])) != byte_size(reference)),
   do: raise("Recorded arrivals must exactly account for the reference PCM")

if reference &&
     (byte_size(reference) > 60 * 48_000 or rem(byte_size(reference), 2) != 0 or
        byte_size(reference) == 0),
   do: raise("Reference must be nonempty mono 24 kHz s16le PCM, at most 60 seconds")

pipeline =
  if System.get_env("AUDIO_BASELINE_PIPELINE") == "1" do
    Code.require_file("../validation/playout-hardening-20261003/baseline_pipeline.exs", __DIR__)
    Parlora.Validation.BaselinePipeline
  else
    Parlora.AudioPipeline
  end

buffering =
  case System.get_env("AUDIO_BUFFERING", "adaptive") do
    "adaptive" -> :adaptive
    "fixed" -> :fixed
    other -> raise "Unsupported buffering mode: #{other}"
  end

buffer_ms = String.to_integer(System.get_env("AUDIO_BUFFER_MS", "120"))
recovery_ms = String.to_integer(System.get_env("AUDIO_RECOVERY_MS", "120"))

channel_options = [
  playback_buffering: buffering,
  playback_buffer_ms: buffer_ms,
  playback_recovery_ms: recovery_ms
]

unless Parlora.Playout.valid_options?(
         buffer_ms,
         %Parlora.Limits{}.audio_queue_bytes,
         channel_options
       ),
       do: raise("Invalid playback bounds")

Application.put_env(:parlora, :audio_benchmark,
  scenario: scenario,
  duration_ms: seconds * 1_000,
  arrival_schedule: arrivals,
  reference_pcm: reference || Parlora.TestSupport.AudioBenchmark.Signal.pcm(seconds * 1_000),
  output_pipeline: pipeline,
  channel_options: channel_options,
  trace_directory: trace_directory
)

{:ok, _} = Agent.start_link(fn -> MapSet.new() end, name: Parlora.Validation.AudioConnections)
{:ok, _} = Bandit.start_link(plug: Parlora.Validation.AudioRouter, ip: {127, 0, 0, 1}, port: 4002)
IO.puts("Audio receiver benchmark: http://127.0.0.1:4002 (synthetic audio; no credentials)")
Process.sleep(:infinity)
