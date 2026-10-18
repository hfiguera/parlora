# Exercise the exact application code that readers copy from the public guide.
[source] =
  Regex.run(
    ~r/<!-- first_voice.exs -->\s*```elixir\n(.*?)\n```/s,
    File.read!("docs/first-session.md"),
    capture: :all_but_first
  )

Code.compile_string(source, "docs/first-session.md")

defmodule Parlora.FirstSessionGuideTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Parlora.{ContextUpdate, Event}
  alias Parlora.TestSupport.{ContractProvider, MemoryAudio, MemoryChannel}

  test "the copied application executes real Jido work and delivers current facts" do
    output =
      capture_io(fn ->
        {runner, session, channel, provider} = boot()
        assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

        request(provider, "hours")
        assert_receive {:context, %ContextUpdate{delegation_id: "hours", content: content}}
        assert content =~ "Demo shop is open Monday to Friday, 09:00 to 17:00"
        assert [job] = Map.values(Parlora.status(session).jobs)
        assert job.status == :completed

        # The same provider delegation cannot dispatch work or speech again.
        request(provider, "hours")
        refute_receive {:context, %ContextUpdate{}}, 50
        assert map_size(Parlora.status(session).jobs) == 1

        # A fresh question can read again; the sample does not suppress new requests.
        request(provider, "fresh-hours")
        assert_receive {:context, %ContextUpdate{delegation_id: "fresh-hours"}}
        assert map_size(Parlora.status(session).jobs) == 2

        :ok = Parlora.close(session, :finish)
        assert :ok = Task.await(runner, 2_000)
        refute Process.alive?(session)
        refute Process.alive?(channel)
        refute Process.alive?(provider)
        refute Process.whereis(FirstVoice.Jido)
      end)

    assert output =~ "Ready. Ask:"
    assert output =~ "Session process stopped."
  end

  test "the demo duration closes the session and releases its Jido supervisor" do
    capture_io(fn ->
      {runner, session, _channel, _provider} = boot()
      assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
      send(runner.pid, {:stop_demo, session})
      assert :ok = Task.await(runner, 2_000)
      refute Process.alive?(session)
      refute Process.whereis(FirstVoice.Jido)
    end)
  end

  test "failed startup exits without claiming readiness or retaining the session" do
    output =
      capture_io(fn ->
        capabilities = %{ContractProvider.profile(%Parlora.AudioFormat{}) | full_duplex?: false}
        {runner, session, channel, provider} = boot(capabilities: capabilities)
        assert :ok = Task.await(runner, 2_000)
        refute Process.alive?(session)
        refute Process.alive?(channel)
        refute Process.alive?(provider)
        refute Process.whereis(FirstVoice.Jido)
      end)

    refute output =~ "Ready. Ask:"
    assert output =~ "Session process stopped."
  end

  defp boot(provider_options \\ []) do
    observer = self()

    runner =
      Task.async(fn ->
        FirstVoice.run(
          channel: {MemoryChannel, observer: observer, delay_ready: true},
          provider:
            {ContractProvider,
             Keyword.merge([observer: observer, delay_ready: true], provider_options)}
        )
      end)

    assert_receive {:adapter, :channel, channel}
    assert_receive {:adapter, :provider, provider}
    session = :sys.get_state(provider).init.event_sink

    on_exit(fn ->
      if Process.alive?(session), do: Parlora.close(session, :cancel)
    end)

    assert :ok = Parlora.subscribe(session)
    send(channel, :ready)
    send(provider, :ready)
    {runner, session, channel, provider}
  end

  defp request(provider, id) do
    assert :ok =
             MemoryAudio.inject(provider, :delegation_requested, %{
               id: id,
               target: :client,
               offset_ms: nil
             })
  end
end
