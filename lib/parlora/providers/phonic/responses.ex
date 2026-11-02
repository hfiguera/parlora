defmodule Parlora.Providers.Phonic.Responses do
  @moduledoc false
  alias Parlora.Providers.Phonic.Protocol

  @covered_instruction "Use the current application update. Do not repeat completed work or an already announced result."

  def association(command, content, true, true), do: %{command | output: %{result: content}}
  def association(command, _content, true, _native?), do: command

  def association(command, content, false, true),
    do: %{command | output: %{result: content, instruction: @covered_instruction}}

  def association(command, _content, false, _native?) do
    output =
      command.output
      |> Map.delete(:result)
      |> Map.put(:instruction, @covered_instruction)

    %{command | output: output}
  end

  def plan(entries, nil), do: {:manual, entries}

  def plan([], _call), do: :wait

  def plan([entry | rest] = entries, call) do
    if owns?(entry, call),
      do: {:native, entry, entry.command, rest},
      else: {:manual, Enum.take_while(entries, &(not owns?(&1, call)))}
  end

  def replaces_unsent?(entry, current, call) when is_binary(call),
    do: owns?(entry, call) and owns?(current, call)

  def replaces_unsent?(_, _, _), do: false

  def closed(entries, call) do
    Enum.flat_map(entries, fn
      %{command: %{type: "tool_call_output", tool_call_id: ^call}, content: content} = entry
      when is_binary(content) ->
        [%{entry | command: Protocol.text(content)}]

      %{command: %{type: "tool_call_output", tool_call_id: ^call}} ->
        []

      entry ->
        [entry]
    end)
  end

  defp owns?(%{command: %{type: "tool_call_output", tool_call_id: call}}, call), do: true
  defp owns?(_, _), do: false
end
