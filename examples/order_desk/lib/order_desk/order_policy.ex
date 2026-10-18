defmodule OrderDesk.OrderPolicy do
  @moduledoc "Application policy for the bounded three-digit order lookup example."
  @behaviour Parlora.ContextPolicy
  alias Parlora.ContextDecision

  @impl true
  def interpret(snapshot, _trigger, options) do
    if observer = Keyword.get(options, :observer),
      do: send(observer, {:interpreting, snapshot.revision})

    {:ok, decide(snapshot, options)}
  end

  defp decide(snapshot, options) do
    case Enum.at(snapshot.tasks, 0) do
      {id, task} ->
        target = %ContextDecision{task_id: id, expected_task_revision: task.revision}

        case order(snapshot, task) do
          nil -> recover(task, target, options)
          order when order == task.input.order -> associate_pending(snapshot, target)
          order -> [%{target | kind: :supersede_task, input: %{order: order}}]
        end

      nil ->
        pending(snapshot, options)
    end
  end

  defp associate_pending(snapshot, target) do
    for {id, %{status: :pending}} <- snapshot.pending_delegations,
        do: %{target | kind: :associate_delegation, delegation_id: id}
  end

  defp pending(snapshot, options) do
    case Enum.find(snapshot.pending_delegations, fn {_id, entry} -> entry.status == :pending end) do
      {id, entry} ->
        target = %ContextDecision{delegation_id: id}

        case order(snapshot, entry) do
          nil -> recover(entry, target, options)
          order -> [%{target | kind: :start_task, input: %{order: order}}]
        end

      nil ->
        []
    end
  end

  defp recover(%{clarification: _clarification}, target, _options),
    do: [%{target | kind: :wait_for_context}]

  defp recover(%{context_wait: %{expired?: true}}, target, _options) do
    [
      %{
        target
        | kind: :request_clarification,
          message:
            "I couldn't identify the order number. Please say the three-digit order number, one digit at a time."
      }
    ]
  end

  defp recover(_entry, target, options),
    do: [
      %{
        target
        | kind: :wait_for_context,
          recheck_after_ms: Keyword.get(options, :clarification_wait_ms, 2_000)
      }
    ]

  defp order(snapshot, entry) do
    transcripts = Enum.reverse(snapshot.transcripts) |> Enum.filter(&(&1.speaker == :user))

    case entry do
      %{clarification: %{context_revision: revision}} ->
        transcripts
        |> Enum.filter(&(Map.get(&1, :arrival_order, -1) >= revision))
        |> text()
        |> number()

      _unclarified ->
        transcripts |> text() |> requested_order()
    end
  end

  defp requested_order(text) do
    text
    |> then(&Regex.split(~r/\border(?: number)?\b/i, &1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reject(fn [before, after_order] ->
      status_question?(before) and number(after_order) == nil
    end)
    |> List.last()
    |> case do
      [_before, after_order] -> number(after_order)
      nil -> nil
    end
  end

  defp status_question?(before) do
    Regex.match?(
      ~r/
      \b(?:
        are\s+you\s+(?:still\s+)?checking(?:\s+on)?
        |what(?:\s+is|\s+s)?\s+(?:the\s+)?status\s+(?:of|on)
        |any\s+(?:updates?|news)\s+(?:on|about)
        |what\s+happened\s+(?:to|with)
      )\s+(?:(?:my|the|that)\s+)?$
    /ix,
      before
    )
  end

  defp text(transcripts) do
    transcripts
    |> Enum.map_join(& &1.delta)
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(~r/(?:one |a )?hundred(?: and)? twenty three|one two three/i, "123")
    |> String.replace(~r/(?:one |a )?hundred(?: and)? twenty four|one two four/i, "124")
  end

  defp number(text) do
    case Regex.scan(~r/\b\d(?:\s*\d)*\b/u, text) |> List.last() do
      [digits] ->
        digits = String.replace(digits, " ", "")
        if byte_size(digits) == 3, do: digits

      nil ->
        nil
    end
  end
end
