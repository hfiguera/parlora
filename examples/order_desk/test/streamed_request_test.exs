defmodule OrderDesk.StreamedRequestTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, ScriptedProvider, Speech, Store}
  alias Parlora.Event

  test "number continuation keeps following operation text without combining unrelated requests" do
    assert Speech.join_number_segments(
             "For order one hundred twenty\n four, change the delivery instructions"
           ) ==
             "For order one hundred twenty four, change the delivery instructions"

    assert Speech.join_number_segments("What items are in order one hundred\n twenty-four") ==
             "What items are in order one hundred twenty-four"

    assert Speech.numbers(
             Speech.join_number_segments("What items are in order one hundred\n twenty-four")
           ) == ["124"]

    assert Speech.incomplete_number?("twenty-four")

    assert Speech.continue_number("Check order one two", "four, please") ==
             "Check order one two four, please"

    for text <- [
          "Check order 123\n124",
          "Check order one hundred twenty\nCheck order 124",
          "Check order 120\n124"
        ] do
      assert Speech.join_number_segments(text) == text
    end
  end

  test "first draft survives a number split by assistant speech" do
    classify = fn input ->
      assert "124" in input.order_candidates
      refute "120" in input.order_candidates
      assert input.new_caller_text =~ "one hundred twenty four"
      {:ok, %{intent: "delivery", order: "124"}}
    end

    {session, provider, actor} = start(classify)
    say(provider, :user, "For order one hundred twenty", 0, 700)
    say(provider, :assistant, "Sure", 750, 800)

    say(
      provider,
      :user,
      " four, change the delivery instructions to leave it at reception",
      900,
      2000
    )

    ScriptedProvider.delegate(provider, "draft")
    settled(session, 1)

    assert [%{order: "124", instructions: "leave it at reception", status: "pending"}] =
             Store.dashboard(actor).proposals
  end

  test "completed refusal consumes its trailing sentence but not a new uncertain request" do
    owner = self()

    classify = fn input ->
      send(owner, {:classified, input.new_caller_text})

      cond do
        input.new_caller_text =~ "another order" ->
          {:error,
           {:uncertain, %{intent: "items", order: "unknown", uncertain_fields: ["target"]}}}

        input.new_caller_text == " instructions" ->
          {:error, {:uncertain, %{intent: "refuse", order: "124", uncertain_fields: ["intent"]}}}

        input.new_caller_text =~ "don't save" ->
          {:ok, %{intent: "refuse", order: "124"}}

        true ->
          {:ok, %{intent: "delivery", order: "124"}}
      end
    end

    {session, provider, actor} = start(classify)
    say(provider, :user, "For order 124 leave it at reception", 0, 1000)
    ScriptedProvider.delegate(provider, "draft")
    settled(session, 1)
    say(provider, :assistant, "The draft is ready", 1100, 1500)
    say(provider, :user, "No, don't save that. Keep the original", 1600, 2600)
    settled(session, 2)
    say(provider, :assistant, "I will reject it", 2650, 2700)
    say(provider, :user, " instructions", 2800, 3200)
    refute_receive {:classified, " instructions"}, 2300
    assert Parlora.status(session).interpretation == :settled
    refute_received {:parlora_event, %Event{type: :clarification_requested}}
    assert [%{status: "rejected"}] = Store.dashboard(actor).proposals
    ScriptedProvider.delegate(provider, "late-refusal")
    await(fn -> Parlora.status(session).delegations["late-refusal"][:status] == :claimed end)
    assert map_size(Parlora.status(session).jobs) == 2
    say(provider, :assistant, "It was rejected", 3300, 4000)
    say(provider, :user, "What items are in another order?", 4100, 5000)

    await(fn ->
      Parlora.status(session).jobs |> Map.values() |> Enum.any?(&Map.has_key?(&1, :clarification))
    end)

    assert Parlora.status(session).interpretation == :unresolved
    assert map_size(Parlora.status(session).jobs) == 2
  end

  test "items follow-up starts without a delegation and a late delegation never duplicates it" do
    classify = fn input ->
      intent = if input.new_caller_text =~ "items", do: "items", else: "status"
      {:ok, %{intent: intent, order: "124"}}
    end

    {session, provider, _actor} = start(classify)
    say(provider, :user, "Check order 124", 0, 1000)
    ScriptedProvider.delegate(provider, "status")
    settled(session, 1)
    say(provider, :assistant, "Out for delivery", 1100, 2000)
    say(provider, :user, "What items are in that", 2100, 2600)
    say(provider, :assistant, "Checking", 2650, 2700)
    say(provider, :user, " order?", 2800, 3200)
    settled(session, 2)
    snapshot = Parlora.snapshot(session)

    assert Enum.any?(snapshot.tasks, fn {_, t} ->
             t.input.operation == "items" and t.delegation_id == nil
           end)

    ScriptedProvider.delegate(provider, "items-late")
    await(fn -> Parlora.status(session).delegations["items-late"][:status] == :claimed end)
    assert map_size(Parlora.status(session).jobs) == 2
    ScriptedProvider.delegate(provider, "items-late")
    settled(session, 2)
  end

  test "an items sentence tail after completed work settles and still permits a new request" do
    owner = self()

    classify = fn input ->
      intent =
        cond do
          input.new_caller_text == " there" ->
            assert input.handled_caller_input == "Do you know what items are"
            assert input.active_task.status == :completed
            send(owner, :classified_tail)
            "handled_continuation"

          input.new_caller_text =~ "items" ->
            "items"

          true ->
            "status"
        end

      {:ok, %{intent: intent, order: "124"}}
    end

    {session, provider, _actor} = start(classify)
    say(provider, :user, "Check order 124", 0, 1000)
    ScriptedProvider.delegate(provider, "status")
    settled(session, 1)
    say(provider, :assistant, "Out for delivery", 1100, 2000)
    say(provider, :user, "Do you know what items are", 2100, 2600)
    settled(session, 2)
    say(provider, :assistant, "Hmm", 2650, 2700)
    say(provider, :user, " there", 2800, 3200)
    assert_receive :classified_tail, 1000
    settled(session, 2)
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 2300
    ScriptedProvider.delegate(provider, "items-tail")
    await(fn -> Parlora.status(session).delegations["items-tail"][:status] == :claimed end)
    assert map_size(Parlora.status(session).jobs) == 2

    say(provider, :assistant, "One desk lamp", 3300, 4000)
    say(provider, :user, "And the delivery status?", 4100, 5000)
    settled(session, 3)
    refute_received {:parlora_event, %Event{type: :clarification_requested}}
  end

  defp start(classify) do
    actor = Parlora.ID.new()

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context: %{actor: actor},
        context_policy: {AppPolicy, classify: classify}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    await(fn -> Parlora.status(session).status == :ready end)
    {session, provider, actor}
  end

  defp say(provider, speaker, delta, start, stop),
    do:
      ScriptedProvider.transcript(provider, %{
        speaker: speaker,
        delta: delta,
        start_ms: start,
        end_ms: stop
      })

  defp settled(session, count),
    do:
      await(fn ->
        s = Parlora.status(session)

        map_size(s.jobs) == count and s.interpretation == :settled and
          Enum.all?(s.jobs, fn {_, j} -> j[:delivery] == :accepted end)
      end)

  defp await(fun, attempts \\ 250)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          await(fun, attempts - 1)
        )
  end
end
