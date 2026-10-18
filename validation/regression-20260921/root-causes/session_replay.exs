# Controlled diagnostic reconstruction; original wire timestamps are not available.
if Application.fetch_env!(:order_desk, :database) != ":memory:",
  do: raise("Run this diagnostic with ORDER_DESK_DATABASE=:memory:")

defmodule MissingDelegationReplay do
  alias OrderDesk.ScriptedProvider
  def until(fun, attempts \\ 100)
  def until(_fun, 0), do: raise("condition not reached")

  def until(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(20)
        until(fun, attempts - 1)

      value ->
        value
    end
  end

  def say(pid, speaker, delta, start, stop),
    do:
      ScriptedProvider.transcript(pid, %{
        speaker: speaker,
        delta: delta,
        start_ms: start,
        end_ms: stop
      })

  def run do
    owner = self()

    classify = fn state ->
      intent = if String.contains?(state.new_caller_text, "items"), do: "items", else: "status"
      send(owner, {:classified, intent})
      {:ok, %{intent: intent, order: "124"}}
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy: {OrderDesk.AppPolicy, classify: classify}
      )

    try do
      provider =
        receive do
          {:scripted_provider, pid} -> pid
        after
          2000 -> raise("no provider")
        end

      until(fn -> Parlora.status(session).status == :ready end)
      say(provider, :user, "Check order 124", 0, 500)
      ScriptedProvider.delegate(provider, "status-request")

      until(fn ->
        Enum.any?(Parlora.status(session).jobs, fn {_, j} ->
          Map.get(j, :delivery) == :accepted
        end)
      end)

      say(provider, :assistant, "Order 124 is out for delivery", 600, 1500)
      say(provider, :user, "What items are in that", 1600, 2000)
      say(provider, :assistant, "Checking", 2050, 2100)
      say(provider, :user, " order?", 2200, 2500)

      receive do
        {:classified, "items"} -> :ok
      after
        2000 -> raise("items not classified")
      end

      until(fn -> Parlora.status(session).interpretation == :settled end)
      before = Parlora.status(session)
      1 = map_size(before.jobs)
      Process.sleep(800)
      1 = map_size(Parlora.status(session).jobs)
      ScriptedProvider.delegate(provider, "items-request")

      until(fn ->
        map_size(Parlora.status(session).jobs) == 2 and
          Enum.all?(Parlora.status(session).jobs, fn {_, j} ->
            Map.get(j, :delivery) == :accepted
          end)
      end)

      after_delegation = Parlora.status(session)

      IO.inspect(
        %{
          without_delegation: %{
            jobs: map_size(before.jobs),
            interpretation: before.interpretation
          },
          with_delegation: %{
            jobs: map_size(after_delegation.jobs),
            interpretation: after_delegation.interpretation
          }
        },
        label: "SESSION_CONTROL"
      )
    after
      Parlora.close(session, :cancel)
    end
  end
end

MissingDelegationReplay.run()
