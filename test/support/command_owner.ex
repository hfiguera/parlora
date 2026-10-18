defmodule Parlora.TestSupport.CommandOwner do
  @moduledoc false
  alias Parlora.{AdapterInit, AdapterOwner, Limits}

  def start do
    init = %AdapterInit{
      event_sink: self(),
      generation: 0,
      session_id: "commands",
      adapter_id: "commands",
      limits: %Limits{}
    }

    deadline = System.monotonic_time(:microsecond) + 2_000_000

    {:ok, owner, watcher} =
      AdapterOwner.start_link(fn ->
        {Parlora.TestSupport.MemoryProvider, init, [], deadline}
      end)

    ExUnit.Callbacks.on_exit(fn -> AdapterOwner.cancel(watcher) end)
    %{owner: owner, watcher: watcher}
  end
end
