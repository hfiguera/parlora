defmodule Parlora.Validation.Stability do
  @moduledoc false

  def integer_env(name, default, maximum) do
    case Integer.parse(System.get_env(name, Integer.to_string(default))) do
      {value, ""} when value > 0 and value <= maximum -> value
      _invalid -> raise "#{name} must be between 1 and #{maximum}"
    end
  end

  def vm_sample do
    {rss, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])

    %{
      beam_bytes: :erlang.memory(:total),
      code_bytes: :erlang.memory(:code),
      binary_bytes: :erlang.memory(:binary),
      ets_bytes: :erlang.memory(:ets),
      rss_bytes: String.trim(rss) |> String.to_integer() |> Kernel.*(1_024),
      processes: :erlang.system_info(:process_count)
    }
  end

  def tree(supervisor) do
    children = Supervisor.which_children(supervisor)
    [supervisor | Enum.flat_map(children, &child_pids/1)]
  end

  defp child_pids({_id, pid, :supervisor, _modules}) when is_pid(pid), do: tree(pid)
  defp child_pids({_id, pid, _type, _modules}) when is_pid(pid), do: [pid]
  defp child_pids(_child), do: []

  def peaks(left, right), do: Map.merge(left, right, fn _key, a, b -> max(a, b) end)

  def process_sample(pids) do
    Enum.reduce(pids, %{process_bytes: 0, mailbox: 0}, fn pid, acc ->
      case Process.info(pid, [:memory, :message_queue_len]) do
        nil ->
          acc

        info ->
          %{
            process_bytes: acc.process_bytes + info[:memory],
            mailbox: max(acc.mailbox, info[:message_queue_len])
          }
      end
    end)
  end

  def report(kind, data), do: IO.puts(Jason.encode!(%{validation: kind, measurements: data}))
end
