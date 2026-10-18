alias OrderDesk.AppPolicy
alias Parlora.{ContextSnapshot, ContextTrigger}

defmodule FollowupReplay do
  def fragment(speaker, delta, arrival, start, stop),
    do: %{speaker: speaker, delta: delta, arrival_order: arrival, start_ms: start, end_ms: stop}

  def snapshot(variant) do
    prefix = "Do you know what items are"

    fragments = [
      fragment(:user, "Hi, I want to check the order one hundred twenty four", 1, 0, 1000),
      fragment(:assistant, "Sure. Let's pull up order 124.", 2, 1100, 1500),
      fragment(:user, "Sorry, I mean one hundred twenty three", 3, 1600, 2300),
      fragment(
        :assistant,
        "Okay, let's check 123. That's on its way and due Friday.",
        4,
        2400,
        3500
      ),
      fragment(:user, prefix, 5, 4000, 4500)
    ]

    status = %{
      revision: 2,
      status: :completed,
      input: %{
        operation: "status",
        order: "123",
        instructions: nil,
        user_revision: 3,
        request_text: "Sorry, I mean one hundred twenty three"
      }
    }

    items = %{
      revision: 1,
      status: :completed,
      input: %{
        operation: "items",
        order: "123",
        instructions: nil,
        user_revision: 5,
        request_text: prefix
      },
      context_wait: %{expired?: true, recheck_key: "7:verify"}
    }

    {fragments, tasks} =
      case variant do
        :prefix ->
          {fragments, %{"status" => status}}

        :whole_request ->
          {List.replace_at(fragments, 4, fragment(:user, prefix <> " there", 5, 4000, 4800)),
           %{"status" => status}}

        tail ->
          {start, stop} = if tail == :overlapping_tail, do: {4400, 4700}, else: {4520, 4580}

          {fragments ++
             [
               fragment(:assistant, "Hmm,", 6, start, stop),
               fragment(:user, " there", 7, 4600, 4800)
             ], %{"status" => status, "items" => items}}
      end

    %ContextSnapshot{
      session_id: "reconstructed-#{variant}",
      revision: 7,
      tasks: tasks,
      transcripts: Enum.reverse(fragments)
    }
  end

  def input(snapshot) do
    parent = self()

    AppPolicy.interpret(snapshot, %ContextTrigger{},
      classify: fn input ->
        send(parent, {:input, input})
        {:ok, %{intent: "none", order: "unknown"}}
      end
    )

    receive do
      {:input, input} -> input
    after
      1000 -> raise "Classifier input not produced"
    end
  end
end
