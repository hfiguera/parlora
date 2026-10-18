# Run from the standalone consumer with MIX_ENV=test and TypeSafe credentials.
# Uses scripts/with_keychain.py; no OpenAI connection or microphone is opened.
defmodule FollowupValidation.Policy do
  def interpret(snapshot, trigger, options) do
    result = OrderDesk.AppPolicy.interpret(snapshot, trigger, [])
    send(Keyword.fetch!(options, :observer), {:policy_checked, snapshot.transcripts, result})
    result
  end
end

defmodule FollowupValidation do
  alias OrderDesk.ScriptedProvider
  alias Parlora.Event

  def run do
    true = is_pid(Process.whereis(OrderDesk.TypeSafe))

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy: {FollowupValidation.Policy, observer: self()}
      )

    try do
      provider =
        receive do
          {:scripted_provider, pid} -> pid
        after
          2_000 -> raise "Missing provider"
        end

      event(:ready)
      ScriptedProvider.say(provider, "Check order one hundred twenty four")
      ScriptedProvider.delegate(provider, "status")
      event(:task_submitted)
      context("out for delivery")
      ScriptedProvider.say(provider, " What items are in that order")
      ScriptedProvider.delegate(provider, "items")
      event(:task_submitted)
      context("Desk lamp")
      followup = " Okay, and do you check in my order"
      ScriptedProvider.say(provider, followup)
      checked(followup)
      settled(session, 500)
      progress = Parlora.status(session)
      2 = map_size(progress.jobs)

      true =
        Enum.all?(progress.jobs, fn {_, j} ->
          j.status == :completed and j.delivery == :accepted
        end)

      true = Enum.all?(progress.delegations, fn {_, d} -> d.status == :claimed end)

      receive do
        {:context, _extra} -> raise "Unexpected clarification or extra result"
      after
        500 -> :ok
      end

      IO.inspect(
        %{
          jobs: 2,
          all_completed_and_accepted: true,
          interpretation: progress.interpretation,
          type_safe: OrderDesk.Interpretation.stats()
        },
        label: "FOLLOWUP_VALIDATION"
      )
    after
      Parlora.close(session, :cancel)
    end
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type}} -> :ok
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

  defp checked(followup) do
    receive do
      {:policy_checked, [%{delta: ^followup} | _], {:ok, []}} ->
        :ok

      {:policy_checked, [%{delta: ^followup} | _], other} ->
        raise "Unsettled followup: #{inspect(other)}"

      {:policy_checked, _, _} ->
        checked(followup)
    after
      8_000 -> raise "Missing followup interpretation"
    end
  end

  defp settled(_session, 0), do: raise("Interpretation did not settle")

  defp settled(session, attempts) do
    if Parlora.status(session).interpretation != :settled do
      Process.sleep(10)
      settled(session, attempts - 1)
    end
  end
end

FollowupValidation.run()
