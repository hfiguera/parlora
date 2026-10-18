defmodule Parlora.Channels.Browser.Signaling do
  @moduledoc """
  Mountable WebSock signaling for one application-owned session.

  The host authenticates and checks the Origin **before** calling `upgrade/2`.
  Supply `start_session: fn channel -> MyApp.start_session(channel) end`. That
  function runs in the socket process and must use `event_sink: self()`.
  Optional `on_ready: fn session -> ... end` supplies an application greeting.
  `channel_options` carries ICE and media settings. No listener starts here.

  The browser sends an offer, candidates, `status`, `disconnect`, or `control`
  with `action` equal to `stop`, `clear`, or `resume`. Microphone mute is local
  to the browser track. Text frames are limited to 64 KiB, signaling to 128
  messages, controls to 512 per socket, and inactivity to 30 seconds. The client
  sends a `ping` every five seconds while connected. No session is restored.

  Wait for `attached` before sending the offer, send local candidates after the
  offer, and queue server candidates until its answer is applied. Session `ready`
  follows negotiation. See the [JSON protocol and minimal client](browser-channel.html#signaling-messages).
  """
  @behaviour WebSock
  alias Parlora.Channels.Browser
  alias Parlora.{Event, ID}
  alias Parlora.Session.Uncertainty

  @doc "Upgrade an already authorized host route to a session WebSocket."
  def upgrade(conn, options) do
    conn
    |> WebSockAdapter.upgrade(__MODULE__, options,
      timeout: 30_000,
      max_frame_size: 65_536,
      compress: false
    )
    |> Plug.Conn.halt()
  end

  @impl true
  def init(options) do
    starter = Keyword.fetch!(options, :start_session)

    channel_options =
      Keyword.get(options, :channel_options, []) |> Keyword.put(:signaling, self())

    case starter.({Browser, channel_options}) do
      {:ok, session} ->
        Process.monitor(session)

        {:ok,
         %{
           session: session,
           channel: nil,
           controls: 0,
           on_ready: Keyword.get(options, :on_ready, fn _session -> :ok end)
         }}

      {:error, _error} ->
        {:stop, :normal, 1011, %{session: nil}}
    end
  end

  @impl true
  def handle_in({bytes, [opcode: :text]}, state) when byte_size(bytes) <= 65_536 do
    case Jason.decode(bytes) do
      {:ok, message} when is_map(message) -> dispatch(message, state)
      _invalid -> {:stop, :normal, 1008, state}
    end
  end

  def handle_in(_frame, state), do: {:stop, :normal, 1009, state}

  @impl true
  def handle_info({:parlora_browser, channel, :attached}, %{channel: nil} = state) do
    Process.monitor(channel)
    %{session_id: session_id} = Parlora.snapshot(state.session)
    push(%{type: "attached", session_id: session_id}, %{state | channel: channel})
  end

  def handle_info({:parlora_browser, channel, {:signal, message}}, %{channel: channel} = state),
    do: push(message, state)

  def handle_info({:parlora_event, %Event{source: :session, type: :ready}}, state) do
    state.on_ready.(state.session)
    push(%{type: "ready"}, state)
  end

  def handle_info({:parlora_event, %Event{source: :session, type: :closed}}, state),
    do: {:stop, :normal, 1000, {:text, Jason.encode!(%{type: "closed"})}, state}

  def handle_info({:parlora_event, %Event{type: :transcript_delta, payload: payload}}, state),
    do:
      push(
        %{
          type: "transcript",
          payload:
            Map.take(payload, [
              :role,
              :text,
              :delta,
              :speaker,
              :item_id,
              :segment_id,
              :start_ms,
              :end_ms
            ])
        },
        state
      )

  def handle_info({:parlora_event, %Event{type: type} = event}, state)
      when type in [
             :response_status,
             :delegation_pending,
             :request_started,
             :request_completed,
             :request_failed,
             :request_uncertain,
             :result_delivery,
             :context_wait_started,
             :clarification_requested,
             :delegation_associated,
             :output_recovery_requested,
             :output_recovered,
             :audio_discontinuity,
             :audio_observed,
             :failed,
             :context_rejected
           ] do
    push(
      %{
        type: "event",
        event: type,
        source: event.source,
        request_id: event.request_id,
        payload:
          Map.take(event.payload, [
            :status,
            :elapsed_ms,
            :evidence,
            :stage,
            :cause,
            :epoch,
            :token,
            :transport_epoch,
            :revision,
            :request_id,
            :total_count,
            :dropped_bytes,
            :capacity_bytes,
            :max_age_ms,
            :queue_bytes,
            :incoming_bytes,
            :oldest_age_us,
            :boundary,
            :gap_id,
            :started_at_us,
            :duration_us,
            :inserted_silence_us,
            :silence_bytes,
            :peak_before,
            :peak_after,
            :source_returned_at_us,
            :source_return_queue_bytes,
            :resume_queue_bytes,
            :source_unavailable_us,
            :recovery_wait_us,
            :recovery_target_us,
            :recovery_release_reason,
            :packets
          ])
          |> uncertainty_reason(event)
          |> audio_diagnostics(event.payload)
      },
      state
    )
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when pid == state.session or pid == state.channel,
      do: {:stop, :normal, 1000, state}

  def handle_info({:parlora_unsubscribed, _id, _reason}, state),
    do: {:stop, :normal, 1013, state}

  def handle_info(_message, state), do: {:ok, state}

  defp uncertainty_reason(payload, %{type: :request_uncertain, payload: details}),
    do: Map.put(payload, :reason, Uncertainty.reason(details[:reason]))

  defp uncertainty_reason(payload, _event), do: payload

  @impl true
  def terminate(_reason, %{session: session}) when is_pid(session),
    do: Parlora.close(session, :cancel)

  def terminate(_reason, _state), do: :ok

  defp dispatch(%{"type" => "ping"}, state), do: push(%{type: "pong"}, state)
  defp dispatch(%{"type" => "disconnect"}, state), do: {:stop, :normal, 1000, state}

  defp dispatch(%{"type" => "status"}, state),
    do:
      push(
        %{
          type: "status",
          status: Parlora.status(state.session),
          media: media_status(state.channel)
        },
        state
      )

  defp dispatch(%{"type" => type} = message, %{channel: channel} = state)
       when type in ["offer", "candidate"] and is_pid(channel) do
    case Browser.signal(channel, message) do
      :ok -> {:ok, state}
      {:error, _error} -> {:stop, :normal, 1008, state}
    end
  end

  defp dispatch(%{"type" => "control", "action" => action}, %{controls: count} = state)
       when count < 512 and action in ["stop", "clear", "resume"] do
    control =
      case action do
        "stop" -> {:suppress_output, true}
        "resume" -> {:suppress_output, false}
        "clear" -> {:clear_output, :next}
      end

    result = Parlora.control(state.session, control, ID.new())

    push(%{type: "control", action: action, accepted: result == :ok}, %{
      state
      | controls: count + 1
    })
  end

  defp dispatch(_message, state), do: {:stop, :normal, 1008, state}

  # Only numeric receive diagnostics cross signaling; never arbitrary adapter data.
  defp audio_diagnostics(payload, %{audio_trace: trace}) do
    events =
      trace.events
      |> Enum.take(64)
      |> Enum.map(fn event ->
        Map.take(event, [:at_us, :kind, :bytes, :queue_bytes])
      end)

    Map.put(
      payload,
      :audio_trace,
      trace |> Map.take([:elapsed_us, :events_seen, :truncated]) |> Map.put(:events, events)
    )
  end

  defp audio_diagnostics(payload, _event), do: payload

  defp media_status(channel) when is_pid(channel) do
    case Browser.observations(channel) do
      counters when is_map(counters) -> counters
      _unavailable -> %{status: :unavailable}
    end
  end

  defp media_status(_channel), do: %{status: :unavailable}

  defp push(message, state), do: {:push, {:text, Jason.encode!(message)}, state}
end
