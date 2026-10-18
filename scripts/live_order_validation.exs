Code.require_file("../examples/support/order_policy.ex", __DIR__)
Code.require_file("../examples/support/order_agent.ex", __DIR__)

defmodule Parlora.LiveOrderValidation do
  alias Parlora.Event
  alias Parlora.Backends.Jido, as: Backend
  alias Parlora.Channels.LocalAudio
  alias Parlora.Examples.{OrderAgent, OrderPolicy}
  alias Parlora.Providers.OpenAI

  def run do
    observer = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:parlora, :audio, :frame],
        fn _name, measures, metadata, pid ->
          if metadata.direction == :output, do: send(pid, {:output_bytes, measures.bytes})
        end,
        observer
      )

    {:ok, jido} = Jido.start_link(name: Parlora.ValidationJido)
    {:ok, devices} = LocalAudio.devices("CoreAudio")
    input = Enum.find(devices, &(&1.name == "MacBook Pro Microphone"))
    output = Enum.find(devices, &(&1.name == "MacBook Pro Speakers"))

    mapper = fn %{status: status, result: result} ->
      %{status: status, facts: %{order: result.order}, summary: result.summary}
    end

    {:ok, session} =
      Parlora.start_session(
        channel:
          {LocalAudio, host: "CoreAudio", input_device: input.id, output_device: output.id},
        provider: {OpenAI, api_key: Application.fetch_env!(:parlora, :example_api_key)},
        backend:
          {Backend,
           agent: OrderAgent, agent_options: [jido: Parlora.ValidationJido], result: mapper},
        context_policy: {OrderPolicy, []},
        event_sink: self(),
        instructions: """
        Help callers check orders in English. Keep spoken replies very short.
        Backchannel policy: Briefly acknowledge requests.
        Interruption policy: Yield when the caller corrects an order.
        Delegation policy:
        Backend tools: Read-only delivery lookup by three-digit order number.
        Delegate to the backend when: A caller requests an order lookup or corrects its number.
        Do not delegate to the backend when: Greeting or social conversation.
        Keep conversing while the lookup runs. Only report verified current results.
        """
      )

    receive do
      {:parlora_event, %Event{source: :session, type: :ready}} -> :ok
    after
      15_000 -> raise "Session readiness timed out"
    end

    IO.puts("Physical local session ready; synthesized caller will speak through laptop speakers")
    started_at = System.monotonic_time(:millisecond)
    speak(session, "Can you check delivery for order number one hundred twenty three?")
    Process.send_after(self(), :deadline, 30_000)

    try do
      counters =
        receive_events(session, %{
          requests: [],
          started_at: started_at,
          assistant_text: "",
          useful_transcript_ms: nil,
          useful_handoff_ms: nil,
          current_speech: false,
          post_result_handoff: false,
          current_result: false,
          old_discarded: false,
          assistant_transcript: false,
          output_bytes: 0,
          user_fragments: 0,
          delegations: 0,
          policy_errors: 0,
          number_forms: []
        })

      IO.inspect(Map.drop(counters, [:assistant_text, :started_at]), label: "LIVE_ORDER_RESULTS")

      unless counters.current_result and counters.old_discarded and counters.current_speech and
               counters.post_result_handoff and counters.output_bytes > 0,
             do: raise("Integrated order acceptance did not establish every required observation")
    after
      if Process.alive?(session), do: Parlora.close(session)
      :telemetry.detach(handler_id)
      Supervisor.stop(jido)
    end
  end

  defp speak(session, text) do
    :ok = Parlora.control(session, {:suppress_output, true})
    :ok = Parlora.control(session, {:clear_output, 0})
    System.cmd("/usr/bin/say", ["-v", "Samantha", text], stderr_to_stdout: true)
    Process.sleep(400)
    :ok = Parlora.control(session, {:suppress_output, false})
  end

  defp receive_events(session, counters) do
    receive do
      {:parlora_event, %Event{type: :transcript_delta, payload: %{speaker: :user, delta: delta}}} ->
        forms =
          Regex.scan(~r/\d+|hundred|twenty|three|four|order|number|one|and|[:,—-]/i, delta)
          |> List.flatten()

        receive_events(session, %{
          counters
          | user_fragments: counters.user_fragments + 1,
            number_forms: counters.number_forms ++ forms
        })

      {:parlora_event, %Event{type: :delegation_requested}} ->
        receive_events(session, %{counters | delegations: counters.delegations + 1})

      {:parlora_event, %Event{type: type}} when type in [:policy_failed, :policy_rejected] ->
        receive_events(session, %{counters | policy_errors: counters.policy_errors + 1})

      {:parlora_event, %Event{type: :task_submitted, payload: %{request: request}}} ->
        IO.puts(
          "Backend admitted order #{request.input.order}, revision #{request.task_revision}"
        )

        if request.input.order == "123",
          do: speak(session, "Actually, I meant order number one hundred twenty four.")

        receive_events(session, %{counters | requests: [request.input.order | counters.requests]})

      {:parlora_event, %Event{type: :stale_result}} ->
        receive_events(session, %{counters | old_discarded: true})

      {:parlora_event, %Event{type: :request_completed, payload: %{facts: %{order: "124"}}}} ->
        receive_events(session, %{counters | current_result: true, assistant_text: ""})

      {:parlora_event,
       %Event{type: :transcript_delta, payload: %{speaker: :assistant, delta: delta}}} ->
        text = counters.assistant_text <> delta

        current_speech =
          counters.current_result and String.contains?(String.downcase(text), "out for delivery")

        elapsed =
          if current_speech,
            do:
              counters.useful_transcript_ms ||
                System.monotonic_time(:millisecond) - counters.started_at,
            else: nil

        receive_events(session, %{
          counters
          | assistant_transcript: true,
            assistant_text: text,
            current_speech: current_speech,
            useful_transcript_ms: elapsed
        })

      {:parlora_event, %Event{type: :playback_observed, payload: %{stage: :handed_off}}} ->
        receive_events(session, %{
          counters
          | post_result_handoff: counters.post_result_handoff or counters.current_speech,
            useful_handoff_ms:
              if(counters.current_speech,
                do:
                  counters.useful_handoff_ms ||
                    System.monotonic_time(:millisecond) - counters.started_at,
                else: nil
              )
        })

      {:output_bytes, bytes} ->
        receive_events(session, %{counters | output_bytes: counters.output_bytes + bytes})

      {:parlora_event, %Event{source: :session, type: :closed}} ->
        counters

      {:parlora_event, _event} ->
        receive_events(session, counters)

      :deadline ->
        Parlora.close(session, :finish)

        receive do
          {:parlora_event, %Event{source: :session, type: :closed, payload: payload}} ->
            Map.put(counters, :finalized?, payload.finalized?)
        after
          6_000 -> Map.put(counters, :finalized?, false)
        end
    end
  end
end

Parlora.LiveOrderValidation.run()
