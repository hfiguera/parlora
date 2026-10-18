unless System.argv() == ["--live"], do: raise("Use --live for one bounded JEV evaluation")
Logger.configure(level: :warning)

state = %{
  assistant: "Dígame los tres dígitos del número de pedido.",
  recent_dialogue: [%{speaker: :user, text: "Can you check my order?"}],
  proposed: %{message: "Please say the three-digit order number.", input: %{missing: ["order"]}}
}

before = OrderDesk.Interpretation.stats()
first = OrderDesk.Interpretation.clarification(state)
second = OrderDesk.Interpretation.clarification(state)
after_stats = OrderDesk.Interpretation.stats()

unless first == {:ok, "covered"} and second == first and
         after_stats.calls - before.calls == 1 and after_stats.hits - before.hits == 1,
       do: raise("Live cache probe did not establish one evaluation plus one cache hit")

report = %{
  result: "covered",
  evaluations: 1,
  cache_hits: 1,
  evidence: OrderDesk.Interpretation.evidence()
}

File.write!(Path.join(__DIR__, "cache-probe.json"), Jason.encode!(report, pretty: true) <> "\n")
IO.puts("Live coverage cache verified: one evaluation, one cache hit")
