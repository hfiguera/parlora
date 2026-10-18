defmodule OrderDesk.AppSmoke do
  @moduledoc "Bounded integrated application scenario, optionally using the real TypeSafe service."
  alias OrderDesk.{ScriptedProvider, Store}
  alias Parlora.Event

  def run(policy_opts \\ []) do
    actor = Parlora.ID.new()
    previous = Application.get_env(:order_desk, :lookup_delays)
    Application.put_env(:order_desk, :lookup_delays, %{"123" => 2_000, "124" => 30})

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self()},
        context_policy: {OrderDesk.AppPolicy, policy_opts},
        context: %{actor: actor}
      )

    try do
      provider =
        receive do
          {:scripted_provider, pid} -> pid
        after
          5_000 -> raise "Missing provider"
        end

      event(:ready)
      ScriptedProvider.say(provider, "Check order 123.")
      ScriptedProvider.delegate(provider, "app-123")
      first = event(:task_submitted).payload.request
      ScriptedProvider.say(provider, " Actually, I meant order 124.")
      second = event(:task_submitted).payload.request
      true = first.task_id == second.task_id
      "124" = second.input.order
      context("out for delivery")
      event(:stale_result)
      ScriptedProvider.delegate(provider, "app-124")
      event(:delegation_associated)
      ScriptedProvider.say(provider, " What items are in that order?")
      ScriptedProvider.delegate(provider, "app-items")
      items = event(:task_submitted).payload.request
      "items" = items.input.operation
      true = items.task_id != second.task_id
      context("Desk lamp")
      ScriptedProvider.say(provider, " For delivery of order 124, leave it at reception.")
      ScriptedProvider.delegate(provider, "app-draft")
      draft = event(:task_submitted).payload.request
      "delivery" = draft.input.operation
      context("Nothing has been changed")
      [proposal] = Store.dashboard(actor).proposals
      true = proposal.id == draft.id
      {:ok, %{instructions: before_text}} = Store.order("124")
      ScriptedProvider.say(provider, " No, leave the instructions as they are.")
      Process.sleep(300)
      {:ok, %{instructions: ^before_text}} = Store.order("124")

      %{
        correction: true,
        items: true,
        draft_only: true,
        refusal_did_not_write: true,
        interpretation: OrderDesk.Interpretation.stats()
      }
    after
      Store.dashboard(actor).proposals |> Enum.each(&Store.reject(actor, &1.id))
      Parlora.close(session, :cancel)

      if previous,
        do: Application.put_env(:order_desk, :lookup_delays, previous),
        else: Application.delete_env(:order_desk, :lookup_delays)
    end
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = event} -> event
    after
      8_000 -> raise "Missing application event #{type}"
    end
  end

  defp context(fragment) do
    receive do
      {:context, update} ->
        if String.contains?(update.content, fragment), do: :ok, else: context(fragment)
    after
      8_000 -> raise "Missing verified context #{fragment}"
    end
  end
end
