defmodule Parlora.TestSupport.AudioBenchmark.Source do
  @moduledoc false
  use GenServer
  alias Parlora.Provider.OutputBuffer

  def start_link(init, mode \\ :virtual), do: GenServer.start_link(__MODULE__, {init, mode})
  def push(pid, pcm, now), do: GenServer.call(pid, {:push, pcm, now})
  def clock(pid, now), do: GenServer.call(pid, {:clock, now})
  def write_audio(_pid, _frame), do: :ok
  def read_audio(pid, bytes), do: GenServer.call(pid, {:read, bytes})
  def output_buffer_status(pid), do: GenServer.call(pid, :status)
  def arm_output_ready(pid, reader, ref), do: GenServer.call(pid, {:arm, reader, ref})

  @impl true
  def init({init, mode}) do
    {:ok,
     %{
       init: init,
       queue: OutputBuffer.new(init.limits),
       sequence: 0,
       now: 0,
       mode: mode,
       waiter: nil
     }}
  end

  @impl true
  def handle_call({:clock, now}, _from, state), do: {:reply, :ok, %{state | now: now}}

  def handle_call(:status, _from, state),
    do:
      {:reply, {:ok, %{queued_bytes: state.queue.bytes, capacity_bytes: state.queue.capacity}},
       state}

  def handle_call({:push, pcm, now}, _from, state) do
    case OutputBuffer.push(state.queue, pcm, state.init, state.sequence, now) do
      {:ok, {queue, sequence}} ->
        {:reply, :ok, notify(%{state | queue: queue, sequence: sequence, now: now})}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:read, bytes}, _from, state) do
    case OutputBuffer.read(state.queue, bytes, state.init.limits, clock_now(state)) do
      {:ok, frames, queue} ->
        waiter = if frames == [], do: state.waiter, else: nil
        {:reply, {:ok, frames}, %{state | queue: queue, waiter: waiter}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:arm, reader, ref}, _from, state),
    do: {:reply, :ok, notify(%{state | waiter: {reader, ref}})}

  defp notify(%{waiter: {pid, ref}, queue: %{bytes: bytes}} = state) when bytes > 0 do
    send(pid, {:parlora_audio_ready, self(), ref})
    %{state | waiter: nil}
  end

  defp notify(state), do: state

  defp clock_now(%{mode: :real}), do: System.monotonic_time(:microsecond)
  defp clock_now(state), do: state.now
end
