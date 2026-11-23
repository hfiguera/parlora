defmodule BookingDesk.ApprovalTest do
  use ExUnit.Case, async: true
  alias BookingDesk.Approval
  alias Parlora.ContextSnapshot

  defp fixture(approval \\ "Yes, please", acknowledgment \\ "'Kay") do
    proposal = %{
      id: "proposal",
      revision: 30,
      change: "book",
      slot: "2026-11-05T10:15:00",
      clinician_id: "lee"
    }

    task = %{
      status: :completed,
      input: %{operation: "propose", cursor: 30, revision: 30},
      request_ids: ["proposal"]
    }

    state = %{proposal: proposal, latest_user: acknowledgment}

    parts = [
      {:assistant, "Shall I book November fifth at 10:15 AM with Dr. Lee?", 31, 70_000},
      {:user, approval, 32, 74_000},
      {:assistant, "Okay. Processing that now.", 33, 75_000},
      {:user, acknowledgment, 34, 76_800}
    ]

    transcripts =
      for {speaker, text, cursor, start} <- Enum.reverse(parts),
          do: %{
            speaker: speaker,
            delta: text,
            arrival_order: cursor,
            provider_generation: 0,
            start_ms: start,
            end_ms: start + 200
          }

    {%ContextSnapshot{provider_generation: 0, transcripts: transcripts}, task, state}
  end

  defp prepare({snapshot, task, state}, opts \\ []) do
    Approval.prepare(
      snapshot,
      task,
      state,
      Keyword.merge(
        [approval_continuity: true, approval_readback_judge: fn _ -> {:ok, :ready} end],
        opts
      )
    )
  end

  test "the recorded acknowledgment retains actual caller words and the exact verified readback" do
    fixture = fixture()

    state =
      prepare(fixture,
        approval_readback_judge: fn input ->
          assert input.expected == %{
                   operation: "book",
                   date: "2026-11-05",
                   time: "10:15",
                   clinician: "Dr. Lee"
                 }

          assert input.assistant_text == "Shall I book November fifth at 10:15 AM with Dr. Lee?"
          {:ok, :ready}
        end
      )

    assert state.latest_user == "Yes, please"
    assert state.approval_continuation.approval == "Yes, please"
    assert state.approval_continuation.acknowledgments == ["'Kay"]
  end

  test "conditions, refusals, corrections, questions and bare acknowledgments cannot supply approval" do
    for acknowledgment <- [
          "Wait",
          "No",
          "Yes, but wait",
          "Okay?",
          "Actually November fourth",
          "Okay if insurance covers it"
        ] do
      {_, _, original} = f = fixture("Yes, please", acknowledgment)
      refute Map.has_key?(prepare(f), :approval_continuation)
      assert prepare(f).latest_user == original.latest_user
    end

    for approval <- ["Yes, if it is covered", "No", "Maybe", "Don't book", "Wait", "Yes?"] do
      refute Map.has_key?(prepare(fixture(approval)), :approval_continuation)
    end

    {snapshot, task, state} = fixture()

    snapshot = %{
      snapshot
      | transcripts: Enum.reject(snapshot.transcripts, &(&1.arrival_order == 32))
    }

    refute Map.has_key?(prepare({snapshot, task, state}), :approval_continuation)
  end

  test "stale or absent speech, changed proposals and new approval questions invalidate continuity" do
    {snapshot, task, state} = fixture()

    for snapshot <- [
          %{snapshot | provider_generation: 1},
          update_in(snapshot.transcripts, &Enum.map(&1, fn p -> Map.put(p, :end_ms, nil) end)),
          update_in(snapshot.transcripts, fn [ack | rest] ->
            [%{ack | start_ms: 90_000, end_ms: 90_200} | rest]
          end),
          update_in(snapshot.transcripts, fn [ack, reply | rest] ->
            [ack, %{reply | delta: "Should I book that?"} | rest]
          end),
          update_in(
            snapshot.transcripts,
            &Enum.map(&1, fn p ->
              if p.arrival_order == 31, do: %{p | start_ms: 74_000, end_ms: 74_200}, else: p
            end)
          )
        ] do
      refute Map.has_key?(prepare({snapshot, task, state}), :approval_continuation)
    end

    for proposal <- [
          nil,
          %{state.proposal | id: "new"},
          %{state.proposal | revision: 31},
          %{state.proposal | change: "cancel"}
        ] do
      refute Map.has_key?(
               prepare({snapshot, task, %{state | proposal: proposal}}),
               :approval_continuation
             )
    end

    refute Map.has_key?(
             prepare({snapshot, %{task | input: %{task.input | cursor: 33}}, state}),
             :approval_continuation
           )
  end

  test "readback uncertainty fails closed and other providers retain the original state" do
    for result <- [{:error, :uncertain}, {:error, :unavailable}] do
      refute Map.has_key?(
               prepare(fixture(), approval_readback_judge: fn _ -> result end),
               :approval_continuation
             )
    end

    {_, _, original} = f = fixture()

    assert prepare(f,
             approval_continuity: false,
             approval_readback_judge: fn _ ->
               flunk("disabled provider must not evaluate readback")
             end
           ) == original
  end
end
