defmodule Parlora.TestSupport.MemoryProvider do
  @moduledoc false
  use Parlora.TestSupport.MemoryAudio, role: :provider
  @impl true
  def recover_output(pid, token, snapshot),
    do: Parlora.Adapter.call(pid, {:recover_output, token, snapshot})
end
