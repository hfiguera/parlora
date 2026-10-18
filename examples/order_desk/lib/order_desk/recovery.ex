defmodule OrderDesk.Recovery do
  @moduledoc "Clarify only after stable caller input and a fresh unresolved judgment."
  alias Parlora.ContextDecision, as: Decision

  # An existing recovery owns the conversation until it is claimed. New provider
  # delegations must not replace its question merely because map order changes.
  def pending(snapshot) do
    snapshot.pending_delegations
    |> Enum.filter(fn {_id, entry} -> entry.status == :pending end)
    |> Enum.max_by(
      fn {id, entry} ->
        asked = get_in(entry, [:clarification, :context_revision]) || -1

        waiting =
          case get_in(entry, [:context_wait, :recheck_key]) do
            key when is_binary(key) ->
              case Integer.parse(key) do
                {revision, _phase} -> revision
                :error -> -1
              end

            _ ->
              -1
          end

        {max(asked, waiting), asked, Map.get(entry, :received_at_us, 0), id}
      end,
      fn -> nil end
    )
  end

  def new(active, pending, revision, options) do
    {entry, target} = target(active, pending)

    %{
      entry: entry,
      target: target,
      pending_delegation: pending && elem(pending, 0),
      revision: revision,
      number_settle_ms: Keyword.get(options, :number_settle_ms, 600),
      delivery_settle_ms: Keyword.get(options, :delivery_settle_ms, 600),
      settle_ms: Keyword.get(options, :clarification_settle_ms, 1_500),
      verify_ms: Keyword.get(options, :clarification_verify_ms, 600)
    }
  end

  def awaiting_reply?(%{entry: %{clarification: %{context_revision: asked}}, revision: revision}),
    do: revision <= asked

  def awaiting_reply?(_recovery), do: false

  def verifying?(recovery), do: phase(recovery) == {:verify, true}

  def number_ready?(recovery) do
    case recovery.entry[:context_wait] do
      %{recheck_key: wait_key, expired?: expired} ->
        (wait_key == key(recovery, :number) and expired) or
          wait_key in [key(recovery, :settle), key(recovery, :verify)]

      _missing ->
        false
    end
  end

  def wait_for_number(recovery) do
    [
      %{
        recovery.target
        | kind: :wait_for_context,
          recheck_after_ms: recovery.number_settle_ms,
          recheck_key: key(recovery, :number)
      }
    ]
  end

  def delivery_ready?(recovery) do
    case recovery.entry[:context_wait] do
      %{recheck_key: wait_key, expired?: true} -> wait_key == key(recovery, :delivery)
      _missing -> false
    end
  end

  def wait_for_delivery(recovery) do
    [
      %{
        recovery.target
        | kind: :wait_for_context,
          recheck_after_ms: recovery.delivery_settle_ms,
          recheck_key: key(recovery, :delivery)
      }
    ]
  end

  def wait(%{target: nil}), do: []
  def wait(%{target: target}), do: [%{target | kind: :wait_for_context}]

  def decide(recovery, message, input \\ %{})
  def decide(%{target: nil}, _message, _input), do: []

  def decide(recovery, message, input) do
    case phase(recovery) do
      {phase, true} when phase in [:verify, :coverage] ->
        [
          %{
            recovery.target
            | kind: :request_clarification,
              delegation_id: recovery.pending_delegation || recovery.target.delegation_id,
              message: message,
              input: input,
              clarification_key: Integer.to_string(recovery.revision)
          }
        ]

      {:coverage, false} ->
        wait(recovery)

      {phase, _expired} when phase == :verify ->
        recheck(recovery, :verify)

      {:settle, true} ->
        recheck(recovery, :verify)

      _other ->
        recheck(recovery, :settle)
    end
  end

  defp phase(recovery) do
    case recovery.entry[:context_wait] do
      %{recheck_key: key, expired?: expired} ->
        cond do
          key == key(recovery, :settle) -> {:settle, expired}
          key == key(recovery, :verify) -> {:verify, expired}
          key == key(recovery, :coverage) -> {:coverage, expired}
          true -> :new_input
        end

      _missing ->
        :new_input
    end
  end

  defp recheck(recovery, phase) do
    delay = if phase == :settle, do: recovery.settle_ms, else: recovery.verify_ms

    [
      %{
        recovery.target
        | kind: :wait_for_context,
          recheck_after_ms: delay,
          recheck_key: key(recovery, phase)
      }
    ]
  end

  defp key(recovery, phase), do: "#{recovery.revision}:#{phase}"

  defp target({id, task}, _pending),
    do: {task, %Decision{task_id: id, expected_task_revision: task.revision}}

  defp target(nil, {id, entry}), do: {entry, %Decision{delegation_id: id}}
  defp target(nil, nil), do: {%{}, nil}
end
