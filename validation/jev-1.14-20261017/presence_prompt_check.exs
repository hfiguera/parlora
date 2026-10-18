# Paired prompt check using the same current interpreter, model and typed states.
Logger.configure(level: :error)
[baseline_source, observations, output] = System.argv()
Code.ensure_loaded!(OrderDesk.AppPolicy)
Code.ensure_loaded!(OrderDesk.Clarification)

baseline_source
|> File.read!()
|> String.replace(
  "defmodule OrderDesk.Interpretation do",
  "defmodule OrderDesk.PriorQuestions do",
  global: false
)
|> Code.compile_string()

decode = fn decode, value ->
  cond do
    is_map(value) ->
      Map.new(value, fn {key, value} -> {String.to_existing_atom(key), decode.(decode, value)} end)

    is_list(value) ->
      Enum.map(value, &decode.(decode, &1))

    true ->
      value
  end
end

saved = observations |> File.read!() |> Jason.decode!() |> Map.fetch!("results")

proposed =
  Path.join(__DIR__, "proposed-speech-act-question.json") |> File.read!() |> Jason.decode!()

names = [
  "presence_after_unfinished_read",
  "completed_items_suffix",
  "presence",
  "presence_with_business",
  "presence_during_business_clarification",
  "initial_presence_without_order"
]

rows =
  for name <- names,
      pass <- 1..3,
      variant <- ["original", "proposed"] do
    original = Enum.find(saved, &(&1["name"] == name and &1["pass"] == 1))
    state = decode.(decode, original["input"])
    started = System.monotonic_time(:millisecond)

    questions = OrderDesk.PriorQuestions.questions(state)

    questions =
      if variant == "proposed",
        do:
          Map.put(
            questions,
            "speech_act",
            TypeSafe.choice(proposed["instructions"], proposed["criteria"])
          ),
        else: questions

    {:ok, response} =
      TypeSafe.system_one(OrderDesk.TypeSafe,
        model: "jev-1.13.0",
        state: state,
        questions: questions,
        retry: [max_attempts: 1]
      )

    record = %{
      name: name,
      pass: pass,
      variant: variant,
      returned_model: response.model,
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      judgment: inspect(OrderDesk.Interpretation.interpret_answers(response.answers, state)),
      answers:
        Map.new(response.answers, fn {key, value} ->
          {key, Map.take(value, [:choice, :probabilities])}
        end)
    }

    IO.puts(Jason.encode!(Map.drop(record, [:answers])))
    record
  end

File.write!(
  output,
  Jason.encode!(
    %{
      method:
        "Paired original/proposed speech-act questions, same current arbitration, live pinned jev-1.13.0, six fixed controls, three attempts, no retries.",
      recorded_at: DateTime.utc_now(),
      results: rows
    },
    pretty: true
  ) <> "\n"
)
