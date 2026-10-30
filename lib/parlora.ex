defmodule Parlora do
  @moduledoc """
  An Elixir framework for building real-time voice AI agents.

  Connect speech-to-speech models to your application's services and agent
  backends through browser WebRTC, phone calls, or local audio devices. People
  can keep talking while backend work runs and correct a request during the
  conversation.

  Your application policy interprets requests and corrections. Parlora coordinates
  tasks, filters outdated task results before delivery to the voice provider,
  and manages audio queues, playback controls, lifecycle deadlines, and cleanup.
  Your application owns business rules, authorization, confirmations, and storage.

  Choose a channel, speech provider, backend, and `Parlora.ContextPolicy` for each
  session. All audio passes through Parlora. The provider handles speech and
  delegates application work; the backend executes that work independently.
  Supported integrations and the runnable tutorials are in the
  [README](readme.html) and [first-session guide](first-session.html).

  ## Starting a session

      {:ok, session} = Parlora.start_session(
        channel: {Parlora.Channels.LocalAudio, []},
        provider: {Parlora.Providers.OpenAI, api_key: key},
        backend: backend,
        context_policy: {MyApp.OrderPolicy, []},
        instructions: "Help the caller with their order.",
        event_sink: self()
      )

  `backend` is your configured adapter tuple. Jido, Sagents, and Legion are optional;
  an application can implement `Parlora.Backend` directly. See
  [Getting started](using-parlora.html) for dependencies and a complete setup path.

  Startup is asynchronous. Keep the event sink alive and wait for
  `{:parlora_event, %Parlora.Event{source: :session, type: :ready}}` before inviting
  speech. Handle failures and the session `:closed` event in the same receiver.
  Call `close/2` when finished; monitor the PID if you need to wait for its exit.

  Sessions are in memory. Persist business data in your application and reconcile
  uncertain operations before retrying. Correcting or cancelling work cannot undo
  an external effect, and provider acceptance does not prove a result was heard.
  """
  alias Parlora.{AudioFormat, Error, ID, Limits, Session, SessionSupervisor}

  @doc """
  Starts an asynchronously initialized session.

  Required options are `:channel`, `:provider`, `:backend`, and `:context_policy`,
  each a `{module, keyword_options}` tuple. Optional session settings include
  `:instructions`, `:history`, `:context`, `:event_sink`, `:audio_format`, and
  `:limits`. The default format is mono PCM16LE at 24 kHz; use
  `Parlora.AudioFormat.pcmu/0` for phone audio.

  Provider audio limits are applied automatically, with explicit `:limits`
  overriding them. Returning `{:ok, pid}` does not establish readiness; observe
  the session `:ready` event. See [Getting started](using-parlora.html)
  for session configuration and the provider guides for adapter-specific options.
  """
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(options) do
    with :ok <- validate_options(options),
         {:ok, limits} <-
           Limits.new(
             provider_limits(options),
             Keyword.get(options, :audio_format, %AudioFormat{})
           ) do
      id = ID.new()
      options = options |> Keyword.put(:id, id) |> Keyword.put(:limits, limits)
      spec = %{id: id, start: {SessionSupervisor, :start_link, [options]}, restart: :temporary}

      case DynamicSupervisor.start_child(Parlora.Sessions, spec) do
        {:ok, _supervisor} ->
          pid = GenServer.whereis(SessionSupervisor.via(id, :session))
          send(pid, :start_adapters)
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Subscribes a process to future `{:parlora_event, event}` messages.

  Defaults to the caller. Events are live observations, not a durable replay log.
  """
  @spec subscribe(pid(), pid()) :: :ok | {:error, Error.t()}
  def subscribe(session, subscriber \\ self()), do: Session.subscribe(session, subscriber)

  @doc "Returns current conversation context, including transcripts and task inputs."
  @spec snapshot(pid()) :: Parlora.ContextSnapshot.t() | {:error, Error.t()}
  def snapshot(session), do: Session.snapshot(session)

  @doc "Operational observations. See `Parlora.Status` for fields and clarification privacy."
  @spec status(pid()) :: Parlora.Status.t() | {:error, Error.t()}
  def status(session), do: Session.status(session)

  @doc """
  Arms one opt-in progress deadline on a ready session. See `Parlora.SessionHealth`.
  Reusing an ID with the same options never restarts its deadline.
  """
  @spec expect_progress(pid(), String.t(), pos_integer(), keyword()) :: :ok | {:error, Error.t()}
  def expect_progress(session, id, timeout_ms, options \\ []),
    do: Session.expect_progress(session, id, timeout_ms, options)

  @doc "Resolves or cancels the active expectation without replaying application work."
  @spec resolve_progress(pid(), String.t(), :completed | :cancelled) :: :ok | {:error, Error.t()}
  def resolve_progress(session, id, outcome \\ :completed),
    do: Session.resolve_progress(session, id, outcome)

  @doc "Replaces application context and requests interpretation of the new state."
  @spec update_context(pid(), map()) :: :ok | {:error, Error.t()}
  def update_context(session, context), do: Session.update_context(session, context)

  @doc """
  Submits a structured context update to the voice provider.

  Supported update kinds depend on provider capabilities. Admission, provider
  acknowledgment, generated speech, and playback are separate observations.
  """
  @spec append_context(pid(), Parlora.ContextUpdate.t()) :: :ok | {:error, Error.t()}
  def append_context(session, update), do: Session.append_context(session, update)

  @doc """
  Requests cancellation of a backend request without changing playback.

  Cancellation may be advisory. Reuse an explicit command ID when reconciling an
  uncertain admission; do not assume cancellation reverses external work.
  """
  @spec cancel(pid(), String.t(), term(), String.t()) :: :ok | {:error, Error.t()}
  def cancel(session, request_id, reason, id \\ ID.new()),
    do: Session.cancel(session, id, request_id, reason)

  @doc """
  Applies a supported input or output control.

  Controls include `{:input_muted, boolean}`, `{:suppress_output, boolean}`, and
  `{:clear_output, :next}`. Mute, suppression, clearing, and backend cancellation
  are independent. Reuse the command ID when reconciling an uncertain admission.
  """
  @spec control(pid(), term(), String.t()) :: :ok | {:error, Error.t()}
  def control(session, control, id \\ ID.new()), do: Session.control(session, id, control)

  @doc """
  Requests bounded shutdown using `:cancel` (default) or `:finish`.

  `:cancel` stops local work; `:finish` allows work to drain until the shutdown
  deadline. Observe session `:closed` for final outcomes. External work may still
  require reconciliation. Monitor the session PID to wait for process termination.
  """
  @spec close(pid(), atom()) :: :ok | {:error, Error.t()}
  def close(session, policy \\ :cancel), do: Session.close(session, policy)

  defp provider_limits(options) do
    {module, _settings} = Keyword.fetch!(options, :provider)
    format = Keyword.get(options, :audio_format, %AudioFormat{})

    defaults =
      if function_exported?(module, :audio_limits, 1), do: module.audio_limits(format), else: []

    Keyword.merge(defaults, Keyword.get(options, :limits, []))
  end

  defp adapter_option?({module, settings})
       when is_atom(module) and module != nil and is_list(settings),
       do: Keyword.keyword?(settings) and Code.ensure_loaded?(module)

  defp adapter_option?(_option), do: false

  defp validate_options(options) when is_list(options) do
    if Keyword.keyword?(options) and
         Enum.all?(
           [:channel, :provider, :backend, :context_policy],
           &adapter_option?(Keyword.get(options, &1))
         ) do
      :ok
    else
      Error.tuple(
        :invalid_argument,
        "Specify channel, provider, backend, and context_policy tuples"
      )
    end
  end

  defp validate_options(_options),
    do: Error.tuple(:invalid_argument, "Options must be a keyword list")
end
