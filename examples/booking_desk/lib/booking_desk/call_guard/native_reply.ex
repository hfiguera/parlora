defmodule BookingDesk.CallGuard.NativeReply do
  @moduledoc "Track a native result reply without treating tool acceptance as completed speech."
  defstruct [
    :request_id,
    :generation,
    :covered_key,
    published: false,
    speaking: false,
    caller: false
  ]

  def check(reply, {generation, _} = key) do
    reply = if reply.generation in [nil, generation], do: reply, else: %__MODULE__{}
    %{reply | covered_key: if(active?(reply, key), do: key)}
  end

  def active?(reply, {generation, _} = key),
    do: (reply.request_id != nil and reply.generation == generation) or reply.covered_key == key

  def active?(_, _), do: false

  def observe(reply, %{type: :result_delivery, request_id: id, payload: %{stage: stage}}, key)
      when is_binary(id) do
    case {stage, key} do
      {:awaiting_provider, {generation, _}} ->
        %__MODULE__{
          request_id: id,
          generation: generation,
          covered_key: reply.covered_key,
          caller: reply.caller
        }

      {stage, _} when stage in [:unconfirmed, :accepted] and id == reply.request_id ->
        %{reply | published: true}

      {stage, _} when stage in [:stale, :rejected, :not_applicable] and id == reply.request_id ->
        %__MODULE__{}

      _ ->
        reply
    end
  end

  def observe(reply, %{type: :extension, payload: %{kind: :caller_speech, state: state}}, _key),
    do: %{reply | caller: state == :started}

  def observe(
        reply,
        %{type: :provider_speech, generation: generation, payload: %{state: state}},
        _
      )
      when generation == reply.generation or is_nil(generation) do
    case state do
      :speaking when reply.published ->
        %{reply | speaking: true}

      :idle when reply.speaking and not reply.caller ->
        %{reply | request_id: nil, published: false, speaking: false}

      _ ->
        reply
    end
  end

  def observe(reply, _event, _key), do: reply
end
