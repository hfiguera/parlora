defmodule DeviceProbeTest do
  use ExUnit.Case

  defp opened(capacity \\ 960) do
    {:ok, ref} = DeviceProbe.open_test(capacity)
    on_exit(fn -> DeviceProbe.close(ref) end)
    ref
  end

  defp eventually(fun, retries \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, retries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, retries - 1)
        )
  end

  test "pinned BEAM versions" do
    assert System.version() == "1.20.4"
    version = Path.join([to_string(:code.root_dir()), "releases", "29", "OTP_VERSION"])
    assert String.trim(File.read!(version)) == "29.1.2"
  end

  test "capture queue is bounded and overflow is observable" do
    ref = opened(960)
    eventually(fn -> DeviceProbe.stats(ref).dropped > 0 end)
    stats = DeviceProbe.stats(ref)
    assert stats.input_queued <= 960
    assert stats.input_callbacks > 0 and stats.output_callbacks > 0
    assert {:ok, pcm, frames} = DeviceProbe.read(ref, 480)
    assert frames > 0 and frames <= 480
    assert byte_size(pcm) == frames * 2
    assert Enum.all?(for(<<value::signed-little-16 <- pcm>>, do: value == 8192))
  end

  test "playback accepts bounded buffers and clear removes queued audio" do
    ref = opened(48000)
    assert {:ok, 48000} = DeviceProbe.write(ref, :binary.copy(<<0, 0, 0, 0>>, 48000))
    queued = DeviceProbe.stats(ref).output_queued
    assert queued > 0 and queued <= 48000
    cleared = DeviceProbe.clear(ref)
    assert cleared > 0 and cleared <= 48000
    assert DeviceProbe.stats(ref).output_queued == 0
    eventually(fn -> DeviceProbe.stats(ref).underrun > 0 end)
  end

  test "invalid input is rejected without killing the session" do
    assert_raise ArgumentError, fn -> DeviceProbe.open_test(0) end
    assert_raise ArgumentError, fn -> DeviceProbe.open_test(1_000_000) end
    assert {:error, "unknown host"} = DeviceProbe.devices("nonexistent")
    assert {:error, "unknown host"} = DeviceProbe.open("nonexistent", "", "", 960)
    ref = opened()

    for bad <- [<<>>, <<0>>, :binary.copy(<<0>>, 4000), [0, 1]] do
      assert_raise ArgumentError, fn -> DeviceProbe.write(ref, bad) end
    end

    assert_raise ArgumentError, fn -> DeviceProbe.read(ref, 961) end
    assert_raise ArgumentError, fn -> DeviceProbe.stats(make_ref()) end
    refute DeviceProbe.stats(ref).stopped
  end

  test "close is idempotent and callback counts stop advancing" do
    ref = opened()
    eventually(fn -> DeviceProbe.stats(ref).captured > 0 end)
    assert :ok = DeviceProbe.close(ref)
    stats = DeviceProbe.stats(ref)
    assert stats.stopped
    Process.sleep(30)
    assert DeviceProbe.stats(ref) == stats
    assert :ok = DeviceProbe.close(ref)
    assert {:error, :closed} = DeviceProbe.read(ref, 10)
    assert {:error, :closed} = DeviceProbe.write(ref, <<0, 0, 0, 0>>)
  end

  test "owner death stops the worker even if another process retains the resource" do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, ref} = DeviceProbe.open_test(960)
        send(parent, {:resource, ref})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:resource, ref}, 2000
    refute DeviceProbe.stats(ref).stopped
    Process.exit(pid, :kill)
    eventually(fn -> DeviceProbe.stats(ref).stopped end)
    assert :ok = DeviceProbe.close(ref)
  end

  test "repeated sessions and concurrent read write close remain bounded" do
    for _ <- 1..10 do
      ref = opened()

      tasks =
        for n <- 1..32 do
          Task.async(fn ->
            case rem(n, 4) do
              0 -> DeviceProbe.close(ref)
              1 -> DeviceProbe.write(ref, :binary.copy(<<0>>, 1920))
              2 -> DeviceProbe.read(ref, 480)
              3 -> DeviceProbe.clear(ref)
            end
          end)
        end

      Enum.each(tasks, fn task ->
        case Task.await(task) do
          :ok -> :ok
          {:ok, value} when is_integer(value) -> assert value <= 480
          {:ok, pcm, count} -> assert byte_size(pcm) == count * 2
          {:error, :closed} -> :ok
          count when is_integer(count) -> assert count <= 960
        end
      end)

      assert DeviceProbe.stats(ref).stopped
    end
  end
end
