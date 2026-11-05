defmodule BookingDesk do
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.Gemini
  alias Parlora.Providers.Phonic
  @moduledoc "Fictional clinic scheduling through Parlora, JEV and deterministic Jido actions."
  def start(channel, opts \\ []) do
    opts = Keyword.validate!(opts, [:provider, :provider_options, :guard, :event_sink, :policy])
    provider = Keyword.get(opts, :provider, System.get_env("PARLORA_PROVIDER", "openai"))

    provider_adapter = provider(provider, Keyword.get(opts, :provider_options, []))

    {channel_module, channel_opts} = channel
    {outer_observer, channel_opts} = Keyword.pop(channel_opts, :audio_observer)

    guard_opts =
      Keyword.merge(Keyword.get(opts, :guard, []),
        event_sink: Keyword.get(opts, :event_sink, self()),
        audio_observer: outer_observer,
        native_result_replies: native_result_replies?(provider_adapter),
        instruction_updates: provider in ["openai", "phonic"]
      )

    with {:ok, guard} <-
           DynamicSupervisor.start_child(
             BookingDesk.CallGuards,
             {BookingDesk.CallGuard, guard_opts}
           ) do
      result =
        start_session(guard, {channel_module, channel_opts}, provider_adapter, provider, opts)

      case result do
        {:ok, session} -> BookingDesk.CallGuard.bind(guard, session)
        _ -> DynamicSupervisor.terminate_child(BookingDesk.CallGuards, guard)
      end

      result
    end
  end

  defp start_session(
         guard,
         {channel_module, channel_opts},
         provider_adapter,
         provider,
         opts
       ) do
    observer = BookingDesk.CallGuard.observer(guard)

    with {:ok, conversation} <-
           DynamicSupervisor.start_child(
             BookingDesk.Conversations,
             {BookingDesk.Conversation, []}
           ) do
      result =
        Parlora.start_session(
          channel: {channel_module, Keyword.put(channel_opts, :audio_observer, observer)},
          provider: provider_adapter,
          backend:
            {Parlora.Backends.Jido,
             agent: BookingDesk.Agent,
             agent_options: [jido: BookingDesk.Jido],
             result: &map_result/1},
          context_policy:
            {BookingDesk.Policy,
             Keyword.merge(Keyword.get(opts, :policy, []),
               call_guard: guard,
               conversation: conversation,
               phonic_busy: native_result_replies?(provider_adapter)
             )},
          context: %{},
          instructions: instructions(provider),
          event_sink: guard,
          limits: limits(provider)
        )

      case result do
        {:ok, session} -> BookingDesk.Conversation.bind(conversation, session)
        _ -> DynamicSupervisor.terminate_child(BookingDesk.Conversations, conversation)
      end

      result
    end
  end

  defp native_result_replies?({Phonic, options}),
    do: Keyword.get(options, :wait_for_response, Phonic.default_options()[:wait_for_response])

  defp native_result_replies?(_), do: false

  @doc "Example limits: Gemini can generate the longer confirmation/reminder reply ahead of playback."
  def limits("gemini"),
    do:
      Keyword.merge(
        limits("default"),
        OutputBuffer.burst_limits(%Parlora.AudioFormat{}, 20_000)
      )

  def limits(_), do: [job_timeout_ms: 35_000, policy_timeout_ms: 5_000]

  def provider(name, overrides \\ []) do
    {module, variable} =
      case name do
        "openai" -> {Parlora.Providers.OpenAI, "OPENAI_API_KEY"}
        "gemini" -> {Parlora.Providers.Gemini, "GEMINI_API_KEY"}
        "grok" -> {Parlora.Providers.Grok, "XAI_API_KEY"}
        "phonic" -> {Parlora.Providers.Phonic, "PHONIC_API_KEY"}
      end

    options =
      Keyword.put_new(
        provider_options(name, overrides),
        :api_key,
        System.fetch_env!(variable)
      )

    options =
      if voice = assistant_voice(name), do: Keyword.put_new(options, :voice, voice), else: options

    {module, options}
  end

  def provider_options(provider, overrides \\ [])

  def provider_options("gemini", overrides) do
    {:ok, options} =
      Gemini.merge_options(BookingDesk.GeminiSettings.options(), overrides)

    options
  end

  def provider_options("grok", overrides),
    do: Keyword.merge(BookingDesk.GrokSettings.options(), overrides)

  def provider_options(provider, overrides),
    do: Keyword.merge(BookingDesk.PhonicSettings.options(provider), overrides)

  def assistant_voice("gemini"), do: "Sulafat"
  def assistant_voice("grok"), do: BookingDesk.GrokSettings.voice()
  def assistant_voice(_provider), do: nil

  def map_result(%{result: result}) do
    %{
      status:
        if(result["status"] == "failed" || result[:status] == "failed",
          do: :failed,
          else: :completed
        ),
      facts: result[:facts] || result["facts"] || %{},
      summary: result[:summary] || result["summary"]
    }
  end

  def instructions, do: BookingDesk.Instructions.standard()

  # GPT-Live client delegation uses its native handoff token, not a function tool.
  # https://developers.openai.com/api/docs/guides/live-prompting#delegation
  def instructions("openai") do
    instructions() <>
      """

      Delegation policy:
      Backend tools:
      - Appointments: match the patient, confirm or update insurance information on file, check available times, create an exact proposal, and confirm, cancel or reschedule a booking.

      Generate <|SpawnThinking|> when:
      - The caller supplies their full name and date of birth: look up the patient, then ask about the returned insurer.
      - The caller confirms the insurance on file, says it changed, or supplies the new insurance company or plan name.
      - A matched caller asks for availability or corrects the date of a pending search.
      - The caller chooses an offered time: create the backend proposal before asking for approval.
      - The caller explicitly approves the current proposal: submit the booking to the backend.
      - The caller requests cancellation or rescheduling.
      - The caller accepts or declines a text reminder, confirms the destination number, says it changed, or supplies a new number.

      Do not generate <|SpawnThinking|> when:
      - Giving the opening greeting or responding to a greeting with no scheduling request.
      - Asking for missing full name and date of birth before any patient lookup.
      - The caller asks what to bring, asks about progress on existing work, thanks you or says goodbye.
      - You need a brief clarification because the request is incomplete or ambiguous.

      Generate <|SpawnThinking|> before giving an answer that depends on backend work.
      Saying you are checking does not start a lookup. Do not guess results while waiting.
      """
  end

  def instructions("grok"), do: BookingDesk.Instructions.grok()
  def instructions(_provider), do: instructions()
end
