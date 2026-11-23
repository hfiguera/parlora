defmodule BookingDesk.Approval do
  @moduledoc "Re-evaluate recent caller approval across acknowledgments; never cache or grant consent."
  alias BookingDesk.{Consent, Dialogue, Judgment, Readback, Store}

  @acknowledgments ~w(ok okay kay thanks alright understood) ++
                     ["thank you", "all right", "got it"]
  @max_span_ms 5_000

  def prepare(snapshot, latest, state, opts) do
    if Keyword.get(opts, :approval_continuity, false) and eligible?(latest, state.proposal) do
      state = Map.put(state, :approval_context, true)

      case continuation(snapshot, latest, state.proposal) do
        nil -> state
        evidence -> validate_readback(state, evidence, opts)
      end
    else
      state
    end
  end

  defp eligible?(
         %{
           status: :completed,
           input: %{operation: "propose", revision: revision},
           request_ids: [id | _]
         },
         %{id: id, revision: revision, change: "book"}
       ),
       do: true

  defp eligible?(_, _), do: false

  defp continuation(snapshot, latest, proposal) do
    parts =
      Enum.filter(snapshot.transcripts, fn part ->
        part.arrival_order > latest.input.cursor and
          Map.get(part, :provider_generation) == snapshot.provider_generation
      end)

    turns = Dialogue.build(parts, with_cursor: true, limit: 12)
    callers = turns |> Enum.filter(&(&1.speaker == :user)) |> Enum.reverse()
    {acks, previous} = Enum.split_while(callers, &acknowledgment?(&1.text))

    case {acks, previous} do
      {[_ | _], [approval | _]} when length(acks) <= 3 ->
        question =
          turns
          |> Enum.filter(
            &(&1.speaker == :assistant and
                &1.first_cursor < approval.first_cursor)
          )
          |> List.last()

        if question != nil and Consent.unconditional?(approval.text) and
             not intervening_question?(turns, approval) and
             fresh?(parts, question, approval, acks) do
          %{
            approval: approval.text,
            acknowledgments: acks |> Enum.reverse() |> Enum.map(& &1.text),
            question: question.text,
            proposal: proposal
          }
        end

      _ ->
        nil
    end
  end

  defp acknowledgment?(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("'")
    |> String.trim_leading("’")
    |> String.replace(~r/[.,!]/u, "")
    |> then(&(&1 in @acknowledgments))
  end

  defp intervening_question?(turns, approval),
    do:
      Enum.any?(
        turns,
        &(&1.speaker == :assistant and
            &1.first_cursor > approval.first_cursor and String.contains?(&1.text, "?"))
      )

  defp fresh?(parts, question, approval, acks) do
    first_ack = acks |> List.last() |> Map.fetch!(:first_cursor)

    source =
      Enum.filter(
        parts,
        &(&1.speaker == :user and
            &1.arrival_order >= approval.first_cursor and &1.arrival_order < first_ack)
      )

    acknowledgments =
      Enum.filter(
        parts,
        &(&1.speaker == :user and
            &1.arrival_order >= first_ack)
      )

    readback =
      Enum.filter(
        parts,
        &(&1.speaker == :assistant and
            &1.arrival_order >= question.first_cursor and &1.arrival_order < approval.first_cursor)
      )

    with true <- source != [] and acknowledgments != [] and readback != [],
         true <- Enum.all?(source ++ acknowledgments ++ readback, &valid_interval?/1) do
      ordered_and_recent?(source, acknowledgments, readback)
    end
  end

  defp ordered_and_recent?(source, acknowledgments, readback) do
    start = source |> Enum.map(& &1.start_ms) |> Enum.min()
    finish = acknowledgments |> Enum.map(& &1.end_ms) |> Enum.max()
    readback_end = readback |> Enum.map(& &1.end_ms) |> Enum.max()
    approval_end = source |> Enum.map(& &1.end_ms) |> Enum.max()
    ack_start = acknowledgments |> Enum.map(& &1.start_ms) |> Enum.min()

    readback_end <= start and ack_start >= approval_end and finish >= start and
      finish - start <= @max_span_ms
  end

  defp valid_interval?(part) do
    first = Map.get(part, :start_ms)
    last = Map.get(part, :end_ms)
    is_number(first) and is_number(last) and first >= 0 and last >= first
  end

  defp validate_readback(state, evidence, opts) do
    text = Enum.join([evidence.approval | evidence.acknowledgments], " ")
    proposal = evidence.proposal

    input = %{
      assistant_text: evidence.question,
      expected: %{
        date: String.slice(proposal.slot, 0, 10),
        time: String.slice(proposal.slot, 11, 5),
        clinician: Store.clinicians()[proposal.clinician_id],
        operation: "book"
      }
    }

    judge =
      Keyword.get(
        opts,
        :approval_readback_judge,
        fn input -> Judgment.classify(input, evaluator: &Readback.evaluate/1) end
      )

    if byte_size(text) <= 1_000 and judge.(input) == {:ok, :ready},
      do:
        state
        |> Map.put(:latest_user, evidence.approval)
        |> Map.put(:approval_continuation, evidence),
      else: state
  end
end
