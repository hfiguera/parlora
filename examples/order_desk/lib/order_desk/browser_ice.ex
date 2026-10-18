defmodule OrderDesk.BrowserICE do
  @moduledoc "Host-owned ICE configuration and short-lived TURN credential issuance."
  @credential_seconds 600

  def load_env(get_env \\ &System.get_env/1) do
    policy =
      case get_env.("PARLORA_ICE_POLICY") || "all" do
        "all" -> :all
        "relay" -> :relay
        _invalid -> raise ArgumentError, "PARLORA_ICE_POLICY must be all or relay"
      end

    stun = url(get_env.("PARLORA_STUN_URL"), ["stun", "stuns"])
    turn = url(get_env.("PARLORA_TURN_URL"), ["turn", "turns"])

    if policy == :relay and is_nil(turn),
      do: raise(ArgumentError, "Relay policy requires PARLORA_TURN_URL")

    secret = if turn, do: read_secret(get_env.("PARLORA_TURN_SECRET_FILE")), else: nil
    %{policy: policy, stun: stun, turn: turn, secret: secret}
  end

  def client_config(config \\ Application.fetch_env!(:order_desk, :browser_ice)) do
    %{iceServers: servers(config), iceTransportPolicy: Atom.to_string(config.policy)}
  end

  def channel_options do
    config = Application.fetch_env!(:order_desk, :browser_ice)
    [ice_servers: servers(config), ice_transport_policy: config.policy]
  end

  defp servers(config) do
    stun = if config.stun, do: [%{urls: config.stun}], else: []

    if config.turn do
      # Only the expiring credential reaches the browser. The shared key stays
      # in the host and coturn configuration, outside the source package.
      expires = System.os_time(:second) + @credential_seconds
      nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
      username = "#{expires}:#{nonce}"
      credential = :crypto.mac(:hmac, :sha, config.secret, username) |> Base.encode64()
      stun ++ [%{urls: config.turn, username: username, credential: credential}]
    else
      stun
    end
  end

  defp url(nil, _schemes), do: nil

  defp url(value, schemes) do
    uri = URI.parse(value)

    if uri.scheme in schemes and is_binary(uri.path) and byte_size(uri.path) > 0 and
         byte_size(value) <= 2048 and not String.contains?(value, ["@", " ", "\n", "\r"]),
       do: value,
       else: raise(ArgumentError, "Invalid STUN/TURN URL")
  end

  defp read_secret(filename) when is_binary(filename) do
    case File.read(filename) do
      {:ok, bytes} ->
        secret = String.trim(bytes)

        if byte_size(secret) in 32..256,
          do: secret,
          else: raise(ArgumentError, "TURN secret must contain 32–256 bytes")

      {:error, _reason} ->
        raise ArgumentError, "Cannot read PARLORA_TURN_SECRET_FILE"
    end
  end

  defp read_secret(_filename), do: raise(ArgumentError, "Set PARLORA_TURN_SECRET_FILE for TURN")
end
