Code.require_file("runner.ex", __DIR__)
ExUnit.start()

defmodule Parlora.Validation.PipecatTest do
  use ExUnit.Case
  alias Parlora.Validation.Pipecat

  test "missing captures retain wire evidence and late captions without changing scored events" do
    alias Parlora.Providers.OpenAI.Diagnostics
    root = Path.join(System.tmp_dir!(), "pipecat-capture-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pcm = <<1, 0, 2, 0>>
    sample = %{"sample_id" => "missing", "pcm_sha256" => Pipecat.hash(pcm)}
    late = %{at_ms: 4000, delta: "late caption"}
    result = %{status: "ok", events: [], close: %{late_events: [late]}}

    trace =
      Diagnostics.new(self())
      |> Diagnostics.accepted(pcm)
      |> Diagnostics.sent(%{type: "session.input_audio.append", audio: Base.encode64(pcm)})

    Diagnostics.finish(trace, :closed)

    retained =
      Pipecat.retain_diagnostics(result, sample, pcm,
        diagnostics: "missing",
        diagnostic_dir: root
      )

    assert retained.events == []
    assert retained.diagnostics.state == "retained"
    directory = retained.diagnostics.directory
    assert File.read!(Path.join(directory, "wire.pcm")) == pcm
    capture = Jason.decode!(File.read!(Path.join(directory, "capture.json")))
    assert capture["missing_at_deadline"]
    assert capture["late_events"] == [%{"at_ms" => 4000, "delta" => "late caption"}]
    assert capture["wire_pcm_sha256"] == Pipecat.hash(pcm)
    assert capture["accepted_audio_bytes"] != capture["expected_accepted_bytes"]
    assert Bitwise.band(File.stat!(Path.join(directory, "wire.pcm")).mode, 0o777) == 0o600
  end

  test "successful capture is discarded unless all is requested; unavailable is explicit" do
    alias Parlora.Providers.OpenAI.Diagnostics
    pcm = <<0, 0>>
    sample = %{"sample_id" => "success", "pcm_sha256" => Pipecat.hash(pcm)}
    result = %{status: "ok", events: [%{at_ms: 50, delta: "hello"}]}
    Diagnostics.finish(Diagnostics.new(self()), :closed)
    discarded = Pipecat.retain_diagnostics(result, sample, pcm, diagnostics: "missing")
    assert discarded.diagnostics.state == "discarded_success"
    absent = Pipecat.retain_diagnostics(result, sample, pcm, diagnostics: "all")
    assert absent.diagnostics.state == "unavailable"
  end

  test "all mode retains successes and missing mode also retains failed attempts" do
    alias Parlora.Providers.OpenAI.Diagnostics
    root = Path.join(System.tmp_dir!(), "pipecat-retention-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    for {mode, status} <- [{"all", "ok"}, {"missing", "failed"}] do
      sample = %{"sample_id" => status, "pcm_sha256" => Pipecat.hash(<<0, 0>>)}
      result = %{status: status, events: [%{at_ms: 50, delta: "hello"}]}
      Diagnostics.finish(Diagnostics.new(self()), :closed)

      retained =
        Pipecat.retain_diagnostics(result, sample, <<0, 0>>,
          diagnostics: mode,
          diagnostic_dir: root
        )

      assert retained.diagnostics.state == "retained"

      capture =
        Jason.decode!(File.read!(Path.join(retained.diagnostics.directory, "capture.json")))

      refute capture["missing_at_deadline"]
    end
  end

  test "corrupt audio is rejected before opening a session" do
    root =
      Path.join(
        System.tmp_dir!(),
        "parlora-pipecat-corrupt-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "input.pcm"), <<0, 0>>)

    sample = %{
      "sample_id" => "corrupt",
      "pcm_path" => "input.pcm",
      "pcm_sha256" => "wrong",
      "pcm_bytes" => 2
    }

    before_count = DynamicSupervisor.count_children(Parlora.Sessions).active

    assert_raise RuntimeError, "PCM integrity mismatch", fn ->
      Pipecat.run_sample(sample, root, nil, :offline)
    end

    assert DynamicSupervisor.count_children(Parlora.Sessions).active == before_count
  end

  test "real session pipeline paces input, captures fragments and releases the session" do
    root = Path.join(System.tmp_dir!(), "parlora-pipecat-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    pcm = :binary.copy(<<0>>, 5_760)
    File.write!(Path.join(root, "input.pcm"), pcm)

    sample = %{
      "sample_id" => "offline-self-test",
      "pcm_path" => "input.pcm",
      "pcm_sha256" => Pipecat.hash(pcm),
      "pcm_bytes" => byte_size(pcm)
    }

    result = Pipecat.run_sample(sample, root, nil, :offline)
    assert result.status == "ok"
    assert result.mode == :offline
    assert result.close.cleaned_up
    assert result.pacing.bytes == byte_size(pcm) + 3_000 * 48
    assert Enum.map_join(result.events, & &1.delta) == "offline harness check"
    Process.sleep(50)
    assert DynamicSupervisor.count_children(Parlora.Sessions).active == 0
  end
end
