defmodule BookingDesk.CallGuard.NativeReplyTest do
  use ExUnit.Case, async: true
  alias BookingDesk.CallGuard.NativeReply

  defp event(type, payload, request \\ nil),
    do: %Parlora.Event{type: type, payload: payload, request_id: request, generation: 0}

  test "queued results survive pre-tool speech; processing acceptance is not completed speech" do
    reply = NativeReply.check(%NativeReply{}, {0, 10})

    reply =
      NativeReply.observe(
        reply,
        event(:result_delivery, %{stage: :awaiting_provider}, "r"),
        {0, 10}
      )

    reply = NativeReply.observe(reply, event(:provider_speech, %{state: :speaking}), {0, 10})
    reply = NativeReply.observe(reply, event(:provider_speech, %{state: :idle}), {0, 10})
    assert NativeReply.active?(reply, {0, 11})

    reply =
      NativeReply.observe(reply, event(:result_delivery, %{stage: :unconfirmed}, "r"), {0, 10})

    reply = NativeReply.observe(reply, event(:result_delivery, %{stage: :accepted}, "r"), {0, 10})
    assert NativeReply.active?(reply, {0, 11})
    reply = NativeReply.check(reply, {0, 11})
    reply = NativeReply.observe(reply, event(:provider_speech, %{state: :speaking}), {0, 11})
    reply = NativeReply.observe(reply, event(:provider_speech, %{state: :idle}), {0, 11})
    assert NativeReply.active?(reply, {0, 11})
    refute NativeReply.active?(NativeReply.check(reply, {0, 12}), {0, 12})
  end

  test "caller interruption does not mistake an interrupted result for a completed reply" do
    reply = %NativeReply{request_id: "r", generation: 0, published: true, speaking: true}

    reply =
      NativeReply.observe(
        reply,
        event(:extension, %{kind: :caller_speech, state: :started}),
        {0, 10}
      )

    reply = NativeReply.observe(reply, event(:provider_speech, %{state: :idle}), {0, 10})
    assert NativeReply.active?(reply, {0, 11})

    reply =
      NativeReply.observe(
        reply,
        event(:extension, %{kind: :caller_speech, state: :finished}),
        {0, 11}
      )

    reply = NativeReply.observe(reply, event(:provider_speech, %{state: :speaking}), {0, 11})
    reply = NativeReply.observe(reply, event(:provider_speech, %{state: :idle}), {0, 11})
    refute NativeReply.active?(reply, {0, 12})
  end

  test "obsolete results, unrelated delivery and reconnects cannot retain native ownership" do
    reply = %NativeReply{request_id: "r", generation: 0, covered_key: {0, 10}, published: true}

    same =
      NativeReply.observe(reply, event(:result_delivery, %{stage: :accepted}, "other"), {0, 10})

    assert same == reply
    reply = NativeReply.observe(reply, event(:result_delivery, %{stage: :stale}, "r"), {0, 10})
    refute NativeReply.active?(reply, {0, 10})
    old = %NativeReply{request_id: "old", generation: 0, covered_key: {0, 10}}
    refute NativeReply.active?(NativeReply.check(old, {1, 11}), {1, 11})
  end
end
