alias Parlora.{AudioFrame, AudioQueue, Playout}
s = %{Playout.new(120, 9600) | playing?: true}
{_, q, s} = Playout.take(s, %AudioQueue{}, 960, 0)
{s, q, _} = Enum.reduce([{31_000, 1920}, {41_000, 2400}, {51_000, 480}], {s, q, 0}, fn {now, bytes}, {s, q, i} ->
  q = Enum.reduce(1..div(bytes, 480), q, fn n, q ->
    {:ok, q} = AudioQueue.push(q, AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), "probe", i+n))
    q
  end)
  before = q.bytes
  {_, q, next} = Playout.take(s, q, 960, now)
  IO.puts(Jason.encode!(%{at_ms: now/1000, queued_ms: before/48, source_played_bytes: next.source_bytes-s.source_bytes, release_reason: next.release_reason}))
  {next, q, i+div(bytes,480)}
end)
_ = {s,q}
