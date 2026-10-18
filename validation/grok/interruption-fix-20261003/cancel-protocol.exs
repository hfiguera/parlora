# Bounded upstream protocol check; adapter event ordering is covered separately.
# No caller audio, backend work, credentials, or raw remote errors are retained.
defmodule GrokCancelProtocolProbe do
  alias Parlora.AudioFormat
  alias Parlora.Provider.WebSocketConnection
  alias Parlora.Providers.Grok.Protocol

  def run do
    key = System.fetch_env!("XAI_API_KEY")

    {:ok, config} =
      Protocol.start(
        [
          api_key: key,
          reasoning_effort: :high,
          instructions: "Follow the supplied test request. Do not call tools."
        ],
        %AudioFormat{}
      )

    {:ok, socket} =
      WebSocketConnection.connect(
        {:https, "api.x.ai", 443},
        Protocol.path(),
        [{"authorization", "Bearer " <> key}]
      )

    Process.send_after(self(), :deadline, 35_000)

    state = %{
      socket: socket,
      setup: config.setup,
      stage: :setup,
      cancelled: false,
      fresh: nil,
      text: "",
      audio_bytes: 0,
      result: nil
    }

    loop(state)
  end

  defp loop(%{result: result} = state) when result != nil do
    WebSocketConnection.close(state.socket)

    report = %{
      model: Protocol.model(),
      reasoning_effort: :high,
      result: result,
      cancelled_response_observed: state.cancelled,
      fresh_caption: state.text,
      fresh_audio_bytes: state.audio_bytes,
      passed:
        result == :completed and state.cancelled and state.audio_bytes > 0 and
          String.contains?(String.downcase(state.text), "hello")
    }

    IO.puts(Jason.encode!(report))
    unless report.passed, do: System.halt(1)
  end

  defp loop(state) do
    receive do
      :deadline ->
        loop(%{state | result: :timeout})

      message ->
        case WebSocketConnection.receive(state.socket, message) do
          {:ok, socket, frames} ->
            loop(Enum.reduce(frames, %{state | socket: socket}, &frame/2))

          {:error, reason} ->
            loop(%{state | result: reason})
        end
    end
  end

  defp frame(_, %{result: result} = state) when result != nil, do: state
  defp frame(:open, state), do: send_command(state, state.setup)

  defp frame({:ping, bytes}, state) do
    {:ok, socket} = WebSocketConnection.send(state.socket, {:pong, bytes})
    %{state | socket: socket}
  end

  defp frame({:text, json}, state), do: event(Jason.decode!(json), state)
  defp frame({:close, _, _}, state), do: %{state | result: :socket_closed}
  defp frame(_, state), do: state

  defp event(%{"type" => "session.updated"}, %{stage: :setup} = state) do
    %{state | stage: :first}
    |> send_command(Protocol.text("Count aloud from one to one hundred, slowly."))
    |> send_command(Protocol.respond())
  end

  defp event(%{"type" => "response.created"}, %{stage: :first} = state),
    do: send_command(%{state | stage: :cancelling}, Protocol.cancel())

  defp event(
         %{"type" => "response.done", "response" => %{"status" => status}},
         %{stage: :cancelling} = state
       ) do
    %{state | stage: :fresh, cancelled: status == "cancelled"}
    |> send_command(Protocol.text("Stop counting. Say only hello."))
    |> send_command(Protocol.respond())
  end

  defp event(
         %{"type" => "response.created", "response" => %{"id" => id}},
         %{stage: :fresh} = state
       ),
       do: %{state | fresh: id}

  defp event(
         %{"type" => type, "response_id" => id, "delta" => delta},
         %{fresh: id} = state
       )
       when type in ["response.audio_transcript.delta", "response.output_audio_transcript.delta"],
       do: %{state | text: state.text <> delta}

  defp event(
         %{"type" => type, "response_id" => id, "delta" => delta},
         %{fresh: id} = state
       )
       when type in ["response.audio.delta", "response.output_audio.delta"],
       do: %{state | audio_bytes: state.audio_bytes + byte_size(Base.decode64!(delta))}

  defp event(
         %{"type" => "response.done", "response" => %{"id" => id, "status" => status}},
         %{stage: :fresh, fresh: id} = state
       ),
       do: %{state | result: if(status == "completed", do: :completed, else: :fresh_failed)}

  defp event(%{"type" => "error"}, state), do: %{state | result: :provider_error}
  defp event(_, state), do: state

  defp send_command(state, command) do
    {:ok, socket} = WebSocketConnection.send(state.socket, {:text, Jason.encode!(command)})
    %{state | socket: socket}
  end
end

GrokCancelProtocolProbe.run()
