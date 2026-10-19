defmodule Parlora.Channels.Telnyx.Commands do
  @moduledoc """
  Bounded incoming-call commands over Mint. The host supplies `:api_key`.

  Call from an application-supervised worker. Each invocation uses one stable
  `command_id` across at most three attempts and an 8-second total deadline.
  `:max_attempts` (1–3) and `:timeout_ms` (1–30,000) are configurable. HTTP success
  establishes command acceptance only; signed webhooks establish call progress.
  Transport/timeout/5xx failures can leave the remote outcome unknown.
  Errors retain bounded numeric `:telnyx_codes`, never upstream text. An exact
  HTTP 422 / 90018 response also reports `remote_call_state: :ended`; this is
  evidence of call state, not acceptance of this command or an earlier attempt.

  No redirects are followed. `:base_url` defaults to `https://api.telnyx.com/v2`;
  plain HTTP is accepted only for explicit loopback test servers.
  """
  alias Parlora.Channels.Telnyx.HTTP
  alias Parlora.Error

  @actions [:answer, :streaming_start, :streaming_stop, :hangup]

  @doc "Explicit inbound PCMU streaming settings, including authentication and the caller leg."
  def stream_options(url, token) do
    %{
      "stream_url" => url,
      "stream_auth_token" => token,
      "stream_track" => "inbound_track",
      "stream_codec" => "PCMU",
      "stream_bidirectional_mode" => "rtp",
      "stream_bidirectional_codec" => "PCMU",
      "stream_bidirectional_sampling_rate" => 8_000,
      "stream_bidirectional_target_legs" => "self"
    }
  end

  @doc "Submit one supported command; the host retains its ID until the outcome is reconciled."
  def execute(action, call_id, command_id, parameters, options)
      when action in @actions and is_binary(call_id) and byte_size(call_id) in 1..512 and
             is_binary(command_id) and byte_size(command_id) in 1..128 and is_map(parameters) do
    with {:ok, settings} <- settings(options),
         {:ok, body} <- encode_parameters(Map.put(parameters, "command_id", command_id)),
         true <- byte_size(body) <= 16_384 do
      path = settings.uri.path <> "/calls/" <> URI.encode(call_id, &URI.char_unreserved?/1)
      uri = %{settings.uri | path: path <> "/actions/" <> Atom.to_string(action)}
      deadline = System.monotonic_time(:millisecond) + settings.timeout_ms
      attempt(uri, settings, body, command_id, deadline, 1)
    else
      _invalid -> Error.tuple(:invalid_argument, "Invalid Telnyx command configuration")
    end
  end

  def execute(_action, _call_id, _command_id, _parameters, _options),
    do: Error.tuple(:invalid_argument, "Invalid Telnyx command")

  # JSON exposes only raising encoders. Keep invalid host parameters inside
  # the command's sanitized admission error contract, before any network I/O.
  defp encode_parameters(parameters) do
    {:ok, JSON.encode!(parameters)}
  rescue
    _exception -> {:error, :invalid_parameters}
  end

  defp settings(options) do
    key = Keyword.get(options, :api_key)
    timeout = Keyword.get(options, :timeout_ms, 8_000)
    attempts = Keyword.get(options, :max_attempts, 3)
    url = Keyword.get(options, :base_url, "https://api.telnyx.com/v2")

    with true <- is_binary(key) and byte_size(key) > 0 and is_binary(url),
         true <- is_integer(timeout) and timeout in 1..30_000,
         true <- is_integer(attempts) and attempts in 1..3,
         %URI{} = uri <- URI.parse(url),
         true <- valid_uri?(uri) do
      {:ok, %{key: key, timeout_ms: timeout, max_attempts: attempts, uri: uri}}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp valid_uri?(uri) do
    secure = uri.scheme == "https" or (uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"])

    secure and is_binary(uri.host) and is_binary(uri.path) and
      uri.userinfo == nil and uri.query == nil and uri.fragment == nil
  end

  defp attempt(uri, settings, body, id, deadline, number) do
    result = HTTP.post(uri, settings.key, body, deadline)

    case result do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        accepted(response, id, number)

      failure ->
        retry_or_finish(failure, uri, settings, body, id, deadline, number)
    end
  end

  defp accepted(response, id, number) do
    case JSON.decode(response) do
      {:ok, %{"data" => %{"result" => "ok"}}} ->
        {:ok, %{command_id: id, accepted?: true, attempts: number}}

      _invalid ->
        failure(:invalid_response, nil, number)
    end
  end

  defp retry_or_finish(result, uri, settings, body, id, deadline, number) do
    delay = retry_delay(result, 250 * Integer.pow(2, number - 1))

    if retryable?(result) and number < settings.max_attempts and
         System.monotonic_time(:millisecond) + delay < deadline do
      Process.sleep(delay)
      attempt(uri, settings, body, id, deadline, number + 1)
    else
      case result do
        {:ok, %{status: status, body: body}} ->
          failure(:http_error, status, number, response_details(status, body))

        {:error, reason} ->
          failure(reason, nil, number)
      end
    end
  end

  defp retryable?({:ok, %{status: status}}), do: status in [408, 429] or status in 500..599
  defp retryable?({:error, reason}), do: reason in [:transport, :timeout]

  defp retry_delay({:ok, response}, delay), do: max(response.retry_ms, delay)
  defp retry_delay(_error, delay), do: delay

  defp response_details(status, body) do
    case JSON.decode(body) do
      {:ok, %{"errors" => errors}} when is_list(errors) ->
        codes =
          for %{"code" => code} <- errors,
              is_binary(code),
              byte_size(code) == 5,
              code =~ ~r/\A[0-9]{5}\z/,
              do: code

        details = %{telnyx_codes: codes |> Enum.uniq() |> Enum.take(8)}

        if status == 422 and errors != [] and
             Enum.all?(errors, &match?(%{"code" => "90018"}, &1)),
           do: Map.put(details, :remote_call_state, :ended),
           else: details

      _invalid ->
        %{}
    end
  end

  defp failure(reason, status, attempts, details \\ %{}) do
    # Even an eventual rejection cannot disprove execution of an earlier attempt.
    {:error,
     Error.new(
       :adapter_failed,
       "Telnyx command did not establish acceptance",
       Map.merge(details, %{
         reason: reason,
         http_status: status,
         attempts: attempts,
         outcome: :unknown
       })
     )}
  end
end
