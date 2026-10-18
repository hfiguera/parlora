defmodule ParloraSilentSession.Collector do
  use GenServer
  def start_link(directory), do: GenServer.start_link(__MODULE__, directory, name: __MODULE__)

  def init(directory) do
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    {:ok, %{directory: directory, reports: %{}}}
  end

  def handle_info({:parlora_provider_diagnostics, report}, state) do
    id = report.identity.session_id
    true = Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)
    base = Path.join(state.directory, id)
    File.write!(base <> ".pcm", report.pcm)
    File.chmod!(base <> ".pcm", 0o600)
    metadata = Map.delete(report, :pcm)
    File.write!(base <> ".json", Jason.encode!(metadata, pretty: true))
    File.chmod!(base <> ".json", 0o600)
    {:noreply, %{state | reports: Map.put(state.reports, id, Map.drop(metadata, [:events]))}}
  end

  def handle_call({:report, id}, _, state), do: {:reply, state.reports[id], state}
end
