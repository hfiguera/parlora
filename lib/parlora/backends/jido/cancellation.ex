defmodule Parlora.Backends.Jido.Cancellation do
  @moduledoc false
  alias Parlora.Error

  @compile {:no_warn_undefined, {Jido.AgentServer, :cast, 2}}

  def map(mapper, request, reason) do
    Logger.put_process_level(self(), :none)

    case mapper.(request, reason) do
      %{__struct__: Jido.Signal} = signal -> {:ok, signal}
      _invalid -> failed()
    end
  rescue
    _exception -> failed()
  catch
    _kind, _reason -> failed()
  end

  # Only local framework admission runs in the adapter. Application code runs
  # in a separate worker, and a late mapping cannot target a finished request.
  def submit(agent, signal) do
    case Jido.AgentServer.cast(agent, signal) do
      :ok -> :ok
      _error -> failed()
    end
  rescue
    _exception -> failed()
  catch
    _kind, _reason -> failed()
  end

  defp failed, do: Error.tuple(:adapter_failed, "Jido cancellation signal was not admitted")
end
