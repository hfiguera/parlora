defmodule Parlora.Backend do
  @moduledoc """
  Contract for application-owned work, independent of the voice provider.

  Use a built-in adapter from `Parlora.Backends.Jido`, `Parlora.Backends.Sagents`,
  or `Parlora.Backends.Legion`, or implement this behaviour without an agent
  framework. Configure the session with `backend: {module, options}`.

  Admission and completion are separate: `c:submit/2` admits work, then the adapter
  emits correlated events containing the request/task/revision identities from
  `Parlora.BackendRequest`. Results carry verified application facts in
  `Parlora.BackendResult`. Cancellation may be advisory and never implies an undo.

  Your application owns authorization, service timeouts, operation idempotency,
  and reconciliation of uncertain external effects. See the
  [backend contract](public-interfaces.html#6-parlora-backend) for callbacks and events.
  """
  use Parlora.AdapterBehaviour, capabilities: Parlora.Backend.Capabilities
  @callback submit(pid(), Parlora.BackendRequest.t()) :: :ok | {:error, Parlora.Error.t()}
  @callback update(pid(), String.t(), String.t(), Parlora.BackendRequest.t()) ::
              :ok | {:error, Parlora.Error.t()}
  @callback cancel(pid(), String.t(), String.t(), term()) :: :ok | {:error, Parlora.Error.t()}
end
