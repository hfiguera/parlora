# Run from the standalone consumer with MIX_ENV=test and TypeSafe credentials.
# Synthetic channel/provider; real TypeSafe, Jido and in-memory SQLite.
defmodule RefusalValidation do
  alias OrderDesk.{ScriptedProvider, Store}
  alias Parlora.Event

  def run do
    true = is_pid(Process.whereis(OrderDesk.TypeSafe))
    actor = Parlora.ID.new()
    {:ok, before_order} = Store.order("124")

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context: %{actor: actor},
        context_policy: {OrderDesk.AppPolicy, []}
      )

    try do
      provider =
        receive do
          {:scripted_provider, pid} -> pid
        after
          2_000 -> raise "Missing provider"
        end

      event(:ready)

      say(
        provider,
        :user,
        "For order one hundred twenty four, change the delivery instructions to leave it at reception",
        0,
        1_000
      )

      ScriptedProvider.delegate(provider, "draft")
      first = event(:task_submitted).payload.request
      context("A draft for order 124")

      say(
        provider,
        :assistant,
        "I've drafted delivery instructions for order one twenty-four",
        1_100,
        1_900
      )

      say(provider, :user, "No! Don't say the", 2_000, 2_800)
      refusal = event(:task_submitted).payload.request
      true = refusal.input.proposal_id == first.id
      context("was rejected")
      say(provider, :assistant, "Got", 2_850, 2_950)
      say(provider, :user, "'that", 3_000, 3_200)
      {:error, :conflict} = Store.confirm(actor, first.id)
      {:ok, ^before_order} = Store.order("124")
      [draft] = Store.dashboard(actor).proposals
      "rejected" = draft.status

      receive do
        {:context, _extra} -> raise "Unexpected extra clarification"
      after
        3_000 -> :ok
      end

      :settled = Parlora.status(session).interpretation
      2 = map_size(Parlora.status(session).jobs)

      say(provider, :assistant, "I rejected that draft. Nothing was changed.", 3_300, 4_000)
      say(provider, :user, "What items are in order 123?", 4_100, 5_000)
      ScriptedProvider.delegate(provider, "new-items")
      "items" = event(:task_submitted).payload.request.input.operation
      context("Travel mug")

      receive do
        {:context, _extra} -> raise "Unexpected follow-up clarification"
      after
        3_000 -> :ok
      end

      :settled = Parlora.status(session).interpretation
      3 = map_size(Parlora.status(session).jobs)

      IO.inspect(
        %{
          draft: draft.status,
          confirm_blocked: true,
          order_unchanged: true,
          trailing_fragment_settled: true,
          new_request_completed: true,
          interpretation: :settled,
          type_safe: OrderDesk.Interpretation.stats()
        },
        label: "REFUSAL_VALIDATION"
      )
    after
      Parlora.close(session, :cancel)
    end
  end

  defp say(provider, speaker, delta, start, stop),
    do:
      ScriptedProvider.transcript(provider, %{
        speaker: speaker,
        delta: delta,
        start_ms: start,
        end_ms: stop
      })

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = event} -> event
    after
      8_000 -> raise "Missing event #{type}"
    end
  end

  defp context(fragment) do
    receive do
      {:context, update} -> true = String.contains?(update.content, fragment)
    after
      8_000 -> raise "Missing result #{fragment}"
    end
  end
end

RefusalValidation.run()
