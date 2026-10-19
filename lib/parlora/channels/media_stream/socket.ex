defmodule Parlora.Channels.MediaStream.Socket do
  @moduledoc false
  @behaviour WebSock
  alias Parlora.Event

  def upgrade(conn, options, channel_module, owner_tag) do
    options = Keyword.merge(options, channel_module: channel_module, owner_tag: owner_tag)

    conn
    |> WebSockAdapter.upgrade(__MODULE__, options,
      timeout: 30_000,
      max_frame_size: 16_384,
      compress: false
    )
    |> Plug.Conn.halt()
  end

  @impl true
  def init(options) do
    starter = Keyword.fetch!(options, :start_session)
    channel = Keyword.fetch!(options, :channel_options) |> Keyword.put(:transport, self())

    case starter.({Keyword.fetch!(options, :channel_module), channel}) do
      {:ok, session} ->
        Process.monitor(session)
        lifecycle_owner = Keyword.get(options, :lifecycle_owner)
        if is_pid(lifecycle_owner), do: Process.monitor(lifecycle_owner)
        Process.send_after(self(), :pull, 10)

        {:ok,
         %{
           session: session,
           lifecycle_owner: lifecycle_owner,
           channel_module: Keyword.fetch!(options, :channel_module),
           owner_tag: Keyword.fetch!(options, :owner_tag),
           channel: nil,
           pending: [],
           pending_bytes: 0,
           on_ready: Keyword.get(options, :on_ready, fn _session -> :ok end)
         }}

      {:error, _error} ->
        {:stop, :normal, 1011, %{session: nil}}
    end
  end

  @impl true
  def handle_in({bytes, [opcode: :text]}, state) when byte_size(bytes) <= 16_384 do
    case JSON.decode(bytes) do
      {:ok, message} when is_map(message) -> receive_message(state, message, byte_size(bytes))
      _invalid -> {:stop, :normal, 1008, state}
    end
  end

  def handle_in(_frame, state), do: {:stop, :normal, 1009, state}

  @impl true
  def handle_info({tag, channel, :attached}, %{channel: nil, owner_tag: tag} = state) do
    Process.monitor(channel)

    case Enum.reduce_while(
           Enum.reverse(state.pending),
           :ok,
           &replay(state.channel_module, channel, &1, &2)
         ) do
      :ok -> {:ok, %{state | channel: channel, pending: [], pending_bytes: 0}}
      _error -> {:stop, :normal, 1008, %{state | channel: channel}}
    end
  end

  def handle_info({tag, channel, {:send, messages}}, %{channel: channel, owner_tag: tag} = state),
    do: push(messages, state)

  def handle_info({tag, channel, :close}, %{channel: channel, owner_tag: tag} = state),
    do: {:stop, :normal, 1000, state}

  def handle_info(:pull, %{channel: nil} = state) do
    Process.send_after(self(), :pull, 10)
    {:ok, state}
  end

  def handle_info(:pull, state) do
    case state.channel_module.pull(state.channel) do
      {:ok, messages, wait} ->
        Process.send_after(self(), :pull, wait)
        push(messages, state)

      {:error, %{code: :not_ready}} ->
        Process.send_after(self(), :pull, 10)
        {:ok, state}

      _error ->
        {:stop, :normal, 1011, state}
    end
  end

  def handle_info({:parlora_event, %Event{source: :session, type: :ready}}, state) do
    state.on_ready.(state.session)
    {:ok, state}
  end

  def handle_info({:parlora_event, %Event{source: :session, type: :closed}}, state),
    do: {:stop, :normal, 1000, state}

  def handle_info({:parlora_media_stream, :close}, state),
    do: {:stop, :normal, 1000, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when pid == state.session or pid == state.channel or pid == state.lifecycle_owner,
      do: {:stop, :normal, 1000, state}

  def handle_info({:parlora_unsubscribed, _id, _reason}, state),
    do: {:stop, :normal, 1013, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{session: session}) when is_pid(session),
    do: Parlora.close(session, :cancel)

  def terminate(_reason, _state), do: :ok

  defp receive_message(%{channel: nil} = state, message, bytes) do
    if state.pending_bytes + bytes <= 16_384 and Enum.count_until(state.pending, 16) < 16,
      do:
        {:ok,
         %{state | pending: [message | state.pending], pending_bytes: state.pending_bytes + bytes}},
      else: {:stop, :normal, 1009, state}
  end

  defp receive_message(state, message, _bytes) do
    case state.channel_module.receive_message(state.channel, message) do
      :ok -> {:ok, state}
      _error -> {:stop, :normal, 1008, state}
    end
  end

  defp push([], state), do: {:ok, state}
  defp push(messages, state), do: {:push, Enum.map(messages, &{:text, JSON.encode!(&1)}), state}

  defp replay(module, channel, message, :ok) do
    case module.receive_message(channel, message) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end
end
