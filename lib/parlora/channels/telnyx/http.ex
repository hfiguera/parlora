defmodule Parlora.Channels.Telnyx.HTTP do
  @moduledoc false

  # Run in a supervised command worker, never the webhook, media or session loop.
  # A fresh connection per bounded command avoids hidden pool ownership/lifetimes.
  def post(uri, key, body, deadline) do
    scheme = if uri.scheme == "https", do: :https, else: :http
    timeout = remaining(deadline)

    case Mint.HTTP.connect(scheme, uri.host, uri.port,
           mode: :passive,
           protocols: [:http1],
           transport_opts: [timeout: timeout, send_timeout: timeout]
         ) do
      {:ok, conn} ->
        try do
          send_request(conn, uri.path, key, body, deadline)
        after
          Mint.HTTP.close(conn)
        end

      {:error, _reason} ->
        {:error, :transport}
    end
  end

  defp send_request(conn, path, key, body, deadline) do
    headers = [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}]

    case Mint.HTTP.request(conn, "POST", path, headers, body) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, deadline, %{status: nil, body: "", retry_ms: 0, done: false})

      {:error, _conn, _reason} ->
        {:error, :transport}
    end
  end

  defp receive_response(conn, ref, deadline, response) do
    if remaining(deadline) == 0 do
      {:error, :timeout}
    else
      case Mint.HTTP.recv(conn, 0, remaining(deadline)) do
        {:ok, conn, events} -> collect(conn, ref, deadline, response, events)
        {:error, _conn, _reason, _events} -> {:error, :transport}
      end
    end
  end

  defp collect(conn, ref, deadline, response, events) do
    case Enum.reduce_while(events, response, &event(&1, &2, ref)) do
      :oversized -> {:error, :response_too_large}
      %{done: true} = result -> {:ok, result}
      result -> receive_response(conn, ref, deadline, result)
    end
  end

  defp event({:status, ref, status}, response, ref),
    do: {:cont, %{response | status: status}}

  defp event({:data, ref, bytes}, response, ref) do
    if byte_size(response.body) + byte_size(bytes) <= 16_384,
      do: {:cont, %{response | body: response.body <> bytes}},
      else: {:halt, :oversized}
  end

  defp event({:headers, ref, headers}, response, ref) do
    retry_ms =
      headers
      |> Enum.filter(fn {name, _value} -> name in ["retry-after", "x-ratelimit-reset"] end)
      |> Enum.reduce(response.retry_ms, fn {_name, value}, delay ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> max(delay, seconds * 1_000)
          _unrecognized -> max(delay, 30_000)
        end
      end)

    {:cont, %{response | retry_ms: retry_ms}}
  end

  defp event({:done, ref}, response, ref), do: {:cont, %{response | done: true}}
  defp event(_event, response, _ref), do: {:cont, response}
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
