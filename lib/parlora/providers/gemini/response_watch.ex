defmodule Parlora.Providers.Gemini.ResponseWatch do
  @moduledoc false
  alias Parlora.Event

  # This observes a lack of progress, not a failed request or a known turn end.
  # No remote command, retry, reconnection or business action is issued here.
  # More outbound context or caller captions are not assistant progress. Keep
  # the first deadline, including after it has fired, until actual progress.
  def arm(%{response_watch: watch} = state, _cause) when not is_nil(watch), do: state

  def arm(state, cause) do
    token = make_ref()
    timeout = state.response_timeout_ms
    timer = Process.send_after(self(), {:gemini_response_deadline, token}, timeout)

    watch = %{
      token: token,
      timer: timer,
      cause: cause,
      started_at_us: System.monotonic_time(:microsecond),
      delayed?: false
    }

    %{state | response_watch: watch}
  end

  # SILENT finishes a correlated call without scheduling a new spoken reply.
  # It neither starts a new expectation nor erases an earlier one.
  def submitted(state, %{toolResponse: %{functionResponses: [%{scheduling: "SILENT"}]}}),
    do: state

  def submitted(%{status: :ready} = state, _command), do: arm(state, :context_submitted)
  def submitted(state, _command), do: state

  def clear(%{response_watch: nil} = state, _outcome), do: state

  def clear(state, outcome) do
    watch = state.response_watch
    Process.cancel_timer(watch.timer)
    if watch.delayed?, do: emit(state, watch, outcome)
    %{state | response_watch: nil}
  end

  def expire(%{response_watch: %{token: token, delayed?: false} = watch} = state, token) do
    emit(state, watch, :delayed)
    %{state | response_watch: %{watch | delayed?: true}}
  end

  def expire(state, _token), do: state

  defp emit(state, watch, status) do
    Event.emit(state.init, :provider, :response_status, %{
      status: status,
      cause: watch.cause,
      elapsed_ms: div(System.monotonic_time(:microsecond) - watch.started_at_us, 1_000),
      evidence: :local_observation
    })
  end
end
