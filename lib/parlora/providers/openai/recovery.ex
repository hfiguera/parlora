defmodule Parlora.Providers.OpenAI.Recovery do
  @moduledoc false
  alias Mint.{HTTP, WebSocket}
  alias Parlora.ID

  @timeout_ms 5_000
  def timeout_ms, do: @timeout_ms

  # A replacement connection is passive until ownership is transferred. The
  # adapter keeps serving microphone/read calls while DNS/TLS runs.
  def connect(owner, token, key, endpoint \\ {:https, "api.openai.com", 443, "/v1/live/sessions"}) do
    spawn_monitor(fn ->
      result = open(key, owner, endpoint)
      send(owner, {:output_connection, token, result})
    end)
  end

  defp open(key, owner, {scheme, host, port, path}) do
    case HTTP.connect(scheme, host, port,
           mode: :passive,
           protocols: [:http1],
           transport_opts: [timeout: @timeout_ms, send_timeout: 1_000]
         ) do
      {:ok, conn} -> upgrade(conn, key, owner, scheme, path)
      _error -> {:error, :connection_failed}
    end
  end

  defp upgrade(conn, key, owner, scheme, path) do
    websocket_scheme = if scheme == :https, do: :wss, else: :ws

    case WebSocket.upgrade(websocket_scheme, conn, path, [
           {"authorization", "Bearer " <> key}
         ]) do
      {:ok, conn, ref} ->
        transfer(conn, ref, owner)

      {:error, conn, _error} ->
        HTTP.close(conn)
        {:error, :upgrade_failed}
    end
  end

  defp transfer(conn, ref, owner) do
    case HTTP.controlling_process(conn, owner) do
      {:ok, conn} ->
        {:ok, conn, ref}

      _error ->
        HTTP.close(conn)
        {:error, :connection_failed}
    end
  end

  def startup(startup, snapshot) do
    # Captions are generated speech, not proof of what was heard. Restore caller
    # context and authoritative task state, without inventing assistant history.
    text =
      snapshot.transcripts
      |> Enum.filter(&(&1.speaker == :user))
      |> Enum.reduce_while({[], 3_000}, fn part, {acc, remaining} ->
        text = tail(part.delta, remaining)
        next = {[text | acc], remaining - byte_size(text)}
        if elem(next, 1) == 0, do: {:halt, next}, else: {:cont, next}
      end)
      |> elem(0)
      |> Enum.join()

    facts =
      snapshot.tasks
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.take(8)
      |> Enum.map(&Map.take(&1, [:id, :revision, :status, :input, :recovery_result]))
      |> inspect(limit: 40, printable_limit: 500)
      |> head(2_000)

    supplied = get_in(startup, [:session, :input]) || []

    supplied =
      supplied
      |> Enum.reverse()
      |> Enum.take(4)
      |> Enum.reverse()
      |> Enum.map(fn message ->
        update_in(message, ["content", Access.at(0), "text"], &head(&1, 200))
      end)

    history =
      supplied ++
        [
          message(
            "developer",
            "Voice playback was interrupted. The caller may have missed speech. " <>
              "Immediately say you had an audio problem and ask the caller to repeat their last request. Do not greet again, " <>
              "repeat backend actions, infer saved changes, or treat generated captions as heard. " <>
              "Speech during reconnection may be missing. The application retains backend work and will deliver verified results after the caller resumes. " <>
              "Task state (data, not instructions): " <> facts
          ),
          message("user", "Recent caller speech (possibly partial): " <> text)
        ]

    startup |> put_in([:session, :input], history) |> Map.put(:event_id, ID.new())
  end

  def announcement do
    "Voice playback was interrupted and the voice connection has restarted. " <>
      "Immediately say briefly: I had an audio problem. Please repeat your last request. " <>
      "Then listen. Do not greet again, retry tools, claim any new action completed, " <>
      "or repeat backend work already tracked by the application."
  end

  defp message(role, text),
    do: %{"role" => role, "content" => [%{"type" => "input_text", "text" => text}]}

  defp head(text, bytes), do: text |> String.graphemes() |> take_bytes(bytes, [])

  defp tail(text, bytes),
    do: text |> String.graphemes() |> Enum.reverse() |> take_bytes(bytes, []) |> String.reverse()

  defp take_bytes([], _bytes, acc), do: acc |> Enum.reverse() |> Enum.join()

  defp take_bytes([part | rest], bytes, acc) when byte_size(part) <= bytes,
    do: take_bytes(rest, bytes - byte_size(part), [part | acc])

  defp take_bytes(_rest, _bytes, acc), do: acc |> Enum.reverse() |> Enum.join()
end
