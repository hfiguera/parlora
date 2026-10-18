host = System.fetch_env!("CPAL_HOST")

case DeviceProbe.devices(host) do
  devices when is_list(devices) -> IO.inspect(devices, limit: :infinity)
  error -> raise "device discovery failed: #{inspect(error)}"
end
