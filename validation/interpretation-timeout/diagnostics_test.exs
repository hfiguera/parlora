# Offline, run inside a standalone consumer with no TypeSafe key configured.
Code.require_file("collector.exs", __DIR__)
ExUnit.start()

defmodule InterpretationTraceTest do
  use ExUnit.Case, async: false

  test "a real client deadline records its phase without request or credential contents" do
    output = Path.join(System.tmp_dir!(), "parlora-phase-#{System.unique_integer([:positive])}")
    File.mkdir!(output)
    File.chmod!(output, 0o700)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        :gen_tcp.recv(socket, 0, 2000)
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
      File.rm_rf!(output)
    end)

    start_supervised!(
      {TypeSafe.Client,
       name: OrderDesk.TypeSafe,
       api_key: "credential-must-not-appear",
       base_url: "http://127.0.0.1:#{port}",
       protocols: [:http1],
       timeout: 250,
       connect_timeout: 100,
       retry: [max_attempts: 1]}
    )

    collector = start_supervised!({ParloraInterpretationTrace, output})

    assert {:error, %{kind: :timeout}} =
             TypeSafe.system_one(OrderDesk.TypeSafe,
               state: "request-must-not-appear",
               questions: %{"test" => TypeSafe.noul("A private question")}
             )

    # Poll boundedly for the asynchronous stop event without exposing raw state.
    path = Path.join(output, "interpretation-phases.jsonl")
    records = await_stop(path, System.monotonic_time(:millisecond) + 1000)
    assert Enum.any?(records, &(&1["event"] == "stop" and &1["outcome"] == "timeout"))

    assert Enum.any?(records, fn record ->
             Enum.any?(record["requests"] || [], fn r ->
               r["phase"] == "inflight" and is_nil(r["upload_remaining"]) and
                 r["response_bytes"] == 0
             end)
           end)

    contents = File.read!(path)
    refute contents =~ "credential-must-not-appear"
    refute contents =~ "request-must-not-appear"
    refute contents =~ "A private question"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Process.alive?(collector)
  end

  defp await_stop(path, deadline) do
    records = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    if Enum.any?(records, &(&1["event"] == "stop")) do
      records
    else
      assert System.monotonic_time(:millisecond) < deadline, "Missing terminal telemetry"
      Process.sleep(20)
      await_stop(path, deadline)
    end
  end
end
