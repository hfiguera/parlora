[
  inputs: [
    "mix.exs",
    ".*.exs",
    "{config,lib,dev,test,scripts}/**/*.{ex,exs}",
    "examples/*.{ex,exs}",
    "examples/support/**/*.{ex,exs}"
  ],
  subdirectories: [
    "examples/order_desk",
    "examples/observability",
    "validation/optional-backends/consumer"
  ]
]
