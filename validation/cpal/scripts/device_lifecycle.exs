host = System.fetch_env!("CPAL_HOST")
devices = DeviceProbe.devices(host)
input = Enum.find(devices, &(&1.name == System.fetch_env!("CPAL_INPUT") and &1.input != nil))
output = Enum.find(devices, &(&1.name == System.fetch_env!("CPAL_OUTPUT") and &1.output != nil))
{:error, "input device not found"} = DeviceProbe.open(host, "missing-device", output.id, 4800)

for _ <- 1..3 do
  {:ok, ref} = DeviceProbe.open(host, input.id, output.id, 4800)
  Process.sleep(150)
  stats = DeviceProbe.stats(ref)
  if stats.input_callbacks == 0 or stats.output_callbacks == 0, do: raise("missing callbacks")
  :ok = DeviceProbe.close(ref)
  :ok = DeviceProbe.close(ref)
end

parent = self()

owner =
  spawn(fn ->
    {:ok, ref} = DeviceProbe.open(host, input.id, output.id, 4800)
    send(parent, {:opened, ref})

    receive do
      :finish -> :ok
    end
  end)

ref =
  receive do
    {:opened, ref} -> ref
  after
    6000 -> raise "opening timed out"
  end

Process.sleep(150)
if DeviceProbe.stats(ref).input_callbacks == 0, do: raise("capture did not start")
Process.exit(owner, :kill)

stopped =
  Enum.find_value(1..300, fn _ ->
    if DeviceProbe.stats(ref).stopped,
      do: true,
      else:
        (
          Process.sleep(10)
          false
        )
  end)

if not stopped, do: raise("owner death did not stop CPAL streams")
snapshot = DeviceProbe.stats(ref)
Process.sleep(50)
if DeviceProbe.stats(ref) != snapshot, do: raise("callbacks continued after owner death")
:ok = DeviceProbe.close(ref)
IO.puts("DEVICE_LIFECYCLE_PASS repeated_open_close=3 owner_death=stopped missing_device=error")
