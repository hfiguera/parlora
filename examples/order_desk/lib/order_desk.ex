defmodule OrderDesk do
  @moduledoc "Application-owned order lookup using only Parlora's public contracts."

  def start_session(channel, provider, options \\ []) do
    options = OrderDesk.Provider.session_options(provider, options)
    backend = Keyword.get_lazy(options, :backend, &OrderDesk.Backend.selected/0)

    Parlora.start_session(
      Keyword.merge(
        [
          channel: channel,
          provider: provider,
          backend: backend,
          context_policy: {OrderDesk.OrderPolicy, []},
          event_sink: self()
        ],
        options
      )
    )
  end

  def map_result(%{status: status, result: result}),
    do: %{status: status, facts: Map.take(result, [:order]), summary: result.summary}
end
