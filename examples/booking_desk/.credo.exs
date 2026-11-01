%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "dev/", "test/", "mix.exs"], excluded: []},
      strict: true
    }
  ]
}
