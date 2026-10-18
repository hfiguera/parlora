defmodule OrderDesk.TwilioGate do
  @moduledoc "Bounded development admission and one-use call tickets; caller ID is not authentication."
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def admit_request, do: GenServer.call(__MODULE__, :admit_request)
  def issue(params), do: GenServer.call(__MODULE__, {:issue, params})
  def claim(ticket), do: GenServer.call(__MODULE__, {:claim, ticket, self()})

  @impl true
  def init(options) do
    {:ok, %{options: Map.new(options), calls: %{}, tickets: %{}, window: now(), requests: 0}}
  end

  @impl true
  def handle_call(:admit_request, _from, state) do
    state =
      if now() - state.window >= 1_000, do: %{state | requests: 0, window: now()}, else: state

    if state.requests < 20,
      do: {:reply, :ok, %{state | requests: state.requests + 1}},
      else: {:reply, {:error, :rate_limited}, state}
  end

  def handle_call({:issue, params}, _from, state) do
    if params["To"] == state.options.phone_number and params["Direction"] == "inbound" do
      issue_call(state, params["CallSid"])
    else
      {:reply, {:error, :call_not_allowed}, state}
    end
  end

  def handle_call({:claim, ticket, owner}, _from, state) do
    case Map.get(state.tickets, ticket) do
      %{claimed: false, expires: expires} = entry ->
        if expires > now() do
          Process.monitor(owner)
          entry = %{entry | claimed: true, owner: owner}
          {:reply, {:ok, entry.call}, %{state | tickets: Map.put(state.tickets, ticket, entry)}}
        else
          {:reply, {:error, :expired}, state}
        end

      _invalid ->
        {:reply, {:error, :invalid_ticket}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    tickets = Map.reject(state.tickets, fn {_ticket, entry} -> entry.owner == owner end)
    {:noreply, %{state | tickets: tickets}}
  end

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  defp issue_call(state, call) do
    case Map.get(state.calls, call) do
      nil when map_size(state.calls) < 64 ->
        ticket = Parlora.ID.new()
        entry = %{call: call, claimed: false, expires: now() + 60_000, owner: nil}
        reply = {:ok, stream_url(state, ticket)}

        {:reply, reply,
         %{
           state
           | calls: Map.put(state.calls, call, ticket),
             tickets: Map.put(state.tickets, ticket, entry)
         }}

      nil ->
        {:reply, {:error, :call_capacity}, state}

      ticket ->
        repeat_call(state, ticket)
    end
  end

  defp repeat_call(state, ticket) do
    case Map.get(state.tickets, ticket) do
      %{claimed: false, expires: expires} ->
        reply = if expires > now(), do: {:ok, stream_url(state, ticket)}, else: {:error, :expired}
        {:reply, reply, state}

      _claimed_or_closed ->
        {:reply, {:error, :already_claimed}, state}
    end
  end

  defp stream_url(state, ticket),
    do:
      String.replace_prefix(state.options.public_url, "https://", "wss://") <>
        "/twilio/media/" <> ticket

  defp now, do: System.monotonic_time(:millisecond)
end
