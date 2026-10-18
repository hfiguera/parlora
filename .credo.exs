%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "dev/", "test/", "examples/*.{ex,exs}", "examples/support/", "mix.exs"],
        excluded: []
      },
      plugins: [{ExSlop, []}],
      strict: true
    }
  ]
}
