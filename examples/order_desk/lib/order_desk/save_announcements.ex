defmodule OrderDesk.SaveAnnouncements do
  @moduledoc "Bounded application-owned save announcements; transcript evidence is not playback confirmation."
  use GenServer
  require Logger
  alias Parlora.{ContextUpdate, Event, ID}

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def saved(pid, result), do: GenServer.cast(pid, {:saved, result})
  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(options) do
    session = Keyword.fetch!(options, :session)
    monitor = Process.monitor(session)
    :ok = Parlora.subscribe(session)
    tick_ms = Keyword.get(options, :tick_ms, 100)
    Process.send_after(self(), :tick, tick_ms)

    {:ok,
     %{
       session: session,
       monitor: monitor,
       pending: [],
       awaiting_evidence: %{},
       coordinate?:
         Keyword.get(options, :provider) in [Parlora.Providers.Gemini, Parlora.Providers.Grok],
       published_hold: nil,
       versions: %{},
       evidence: %{},
       last_speech: now(),
       last_playback: now(),
       text: "",
       provider_activity: :unknown,
       provider_speech: :unknown,
       tick_ms: tick_ms,
       idle_ms: Keyword.get(options, :idle_ms, 1_000),
       retry_ms: Keyword.get(options, :retry_ms, 6_000),
       deadline_ms: Keyword.get(options, :deadline_ms, 20_000)
     }}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, %{pending: length(state.pending), evidence: state.evidence}, state}

  @impl true
  def handle_cast({:saved, result}, state) do
    cond do
      result.version <= Map.get(state.versions, result.order, 0) ->
        {:noreply, state}

      not Map.has_key?(state.versions, result.order) and map_size(state.versions) >= 8 ->
        Logger.warning(
          "Save announcement order capacity reached; review the saved state on the page"
        )

        {:noreply, state}

      true ->
        item = %{
          result: result,
          attempts: 0,
          command: nil,
          sent_at: nil,
          due: now() + state.deadline_ms
        }

        pending = Enum.reject(state.pending, &(&1.result.order == result.order)) ++ [item]

        next = %{
          state
          | pending: pending,
            versions: Map.put(state.versions, result.order, result.version),
            text: "",
            last_speech: now(),
            awaiting_evidence: Map.delete(state.awaiting_evidence, result.order)
        }

        {:noreply, next |> evidence(result, :waiting_for_pause) |> coordinate()}
    end
  end

  @impl true
  def handle_info(
        {:parlora_event, %Event{source: :provider, type: :transcript_delta, payload: payload}},
        state
      ) do
    text =
      if payload.speaker == :assistant,
        do: String.slice(state.text <> payload.delta, -2_048, 2_048),
        else: ""

    state = %{state | text: text, last_speech: now()}
    # Conservative evidence: the generated words contain a saved statement and
    # a narrowly normalized destination. This can miss paraphrases, and never proves hearing.
    {announced, pending} =
      Enum.split_with(state.pending, &(&1.attempts > 0 and confirmation?(text, &1.result)))

    state =
      Enum.reduce(announced, %{state | pending: pending}, fn item, acc ->
        evidence(acc, item.result, :transcript_observed)
      end)

    late = Map.get(state, :awaiting_evidence, %{})

    {observed, remaining} =
      Enum.split_with(late, fn {_order, result} -> confirmation?(text, result) end)

    state =
      Enum.reduce(observed, Map.put(state, :awaiting_evidence, Map.new(remaining)), fn {_order,
                                                                                        result},
                                                                                       acc ->
        evidence(acc, result, :transcript_observed)
      end)

    {:noreply, coordinate(state)}
  end

  def handle_info({:parlora_event, %Event{type: type, command_id: id}}, state)
      when type in [:context_acknowledged, :context_rejected, :context_submitted] do
    state =
      Enum.reduce(state.pending, state, fn item, acc ->
        if item.command != nil and item.command == id,
          do:
            evidence(
              acc,
              item.result,
              %{
                context_acknowledged: :provider_acknowledged,
                context_rejected: :provider_rejected,
                context_submitted: :submission_unconfirmed
              }[type]
            ),
          else: acc
      end)

    {:noreply, state}
  end

  def handle_info({:parlora_event, %Event{source: :session, type: :closed}}, state),
    do: {:stop, :normal, state}

  def handle_info(
        {:parlora_event,
         %Event{source: :provider, type: :provider_activity, payload: %{state: activity}}},
        state
      ),
      do: {:noreply, %{state | provider_activity: activity}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:parlora_event,
         %Event{source: :provider, type: :provider_speech, payload: %{state: speech}}},
        state
      ),
      do: {:noreply, %{state | provider_speech: speech, last_speech: now()}}

  def handle_info(
        {:parlora_event, %Event{source: :channel, type: :playback_observed, payload: payload}},
        state
      ) do
    # Browser RTP continues during silence. Only source audio extends the pause;
    # queue/handoff observations are conservative timing, never proof of hearing.
    active =
      payload.stage in [:queued, :handed_off, :estimated_playback, :device_reported_playback]

    source? = payload.stage != :handed_off or Map.get(payload, :source_audio?, false)

    if active and source?,
      do: {:noreply, %{state | last_playback: now()}},
      else: {:noreply, state}
  end

  def handle_info(:tick, state) do
    state = state |> advance() |> coordinate()
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  catch
    :exit, _closed -> {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp advance(state) do
    {expired, pending} = Enum.split_with(state.pending, &(&1.due <= now()))

    state =
      Enum.reduce(expired, %{state | pending: pending}, fn item, acc ->
        Logger.warning(
          "Save announcement ended without matching transcript evidence; saved data is unchanged"
        )

        evidence(acc, item.result, :unconfirmed)
      end)

    case state.pending do
      [item | rest] ->
        ready = item.attempts == 0 or now() - item.sent_at >= state.retry_ms

        if paused?(state) and
             ready and item.attempts < if(state.coordinate?, do: 1, else: 2),
           do: submit(state, item, rest),
           else: state

      [] ->
        state
    end
  end

  defp paused?(state) do
    # OpenAI can stream source silence continuously and has no utterance-state
    # contract. Retain its existing caption-pause behavior. Only providers that
    # report speech state can use source-audio quiescence as an additional guard.
    last_output =
      if state.provider_speech == :unknown,
        do: state.last_speech,
        else: max(state.last_speech, state.last_playback)

    state.provider_activity != :in_progress and state.provider_speech != :speaking and
      now() - last_output >= state.idle_ms
  end

  defp submit(state, item, rest) do
    result = item.result
    id = ID.new()

    update = %ContextUpdate{
      id: id,
      provider_generation: 0,
      kind: if(item.attempts == 0, do: :speakable, else: :instruction),
      content:
        "The application confirmed and saved delivery instructions for order #{result.order}: #{result.instructions}. Record version #{result.version}. This is a verified database update authorized by the browser confirmation. The earlier request to press Confirm is obsolete. If you have not already announced this saved update, tell the caller now, briefly, including the order and quoting the saved text exactly: #{inspect(result.instructions)}. Do not correct or paraphrase the quoted text. Do not wait for them to say they confirmed it or ask them to confirm again."
    }

    outcome =
      case OrderDesk.Provider.append_context(state.session, update) do
        :ok -> :submitted
        {:error, _error} -> :submission_failed
      end

    item = %{item | command: id, attempts: item.attempts + 1, sent_at: now()}

    awaiting =
      if outcome == :submitted,
        do: Map.put(state.awaiting_evidence, result.order, result),
        else: state.awaiting_evidence

    evidence(
      %{state | pending: [item | rest], text: "", awaiting_evidence: awaiting},
      result,
      outcome
    )
  end

  # Publish only an application-owned, expiring coordination lease. This never
  # changes provider instructions or asserts that the announcement was heard.
  defp coordinate(%{coordinate?: true} = state) do
    hold = state.pending |> Enum.map(& &1.due) |> Enum.max(fn -> nil end)

    if hold == state.published_hold do
      state
    else
      context = Parlora.snapshot(state.session).application_context

      :ok =
        Parlora.update_context(state.session, Map.put(context, :save_announcement_until_ms, hold))

      %{state | published_hold: hold}
    end
  end

  defp coordinate(state), do: state

  defp confirmation?(text, result) do
    normalized = normalize(text)

    Regex.match?(~r/\b(?:saved|updated)\b/u, normalized) and
      not Regex.match?(~r/\b(?:not|never|cannot|[\p{L}]+n't)\b/u, normalized) and
      result.order in OrderDesk.Speech.numbers(text) and
      destination?(normalized, result.instructions)
  end

  defp destination?(text, instructions) do
    literal = normalize(instructions)

    contains_words?(text, literal) or
      contains_words?(destination(text), destination(literal))
  end

  # Paired single quotes delimit a phrase without erasing apostrophes inside
  # words. Require both quotes so a streamed prefix such as 'front door cannot
  # confirm a different destination such as 'front doorway'.
  defp contains_words?(text, words) do
    words != "" and
      String.contains?(" " <> text <> " ", [" " <> words <> " ", " '" <> words <> "' "])
  end

  # Only these grammatical alternatives are equivalent for this demo. Do not
  # erase arbitrary prepositions (in the garage differs from at the garage),
  # locations, negation, or possession by another named person.
  defp destination(text) do
    text
    |> String.replace(~r/\b(?:left|leave)(?: it)?\b/u, "leave")
    |> String.replace(~r/\byour\b/u, "my")
    |> String.replace(~r/\bin my front door\b/u, "at my front door")
  end

  # Comparison only: preserve stored and announced text. Canonicalize quote style
  # and this spelling pair without erasing apostrophes in contractions or names.
  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\bneighbour\b/u, "neighbor")
    |> String.replace(~r/[‘’]/u, "'")
    |> String.replace(~r/[^\p{L}\p{N}']+/u, " ")
    |> String.trim()
  end

  defp evidence(state, result, stage),
    do: %{
      state
      | evidence: Map.put(state.evidence, result.order, %{version: result.version, stage: stage})
    }

  defp now, do: System.monotonic_time(:millisecond)
end
