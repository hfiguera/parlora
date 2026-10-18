defmodule Parlora.Provider.History do
  @moduledoc false

  def valid?(history) when is_list(history),
    do: Enum.count_until(history, 129) <= 128 and Enum.all?(history, &valid_message?/1)

  def valid?(_history), do: false

  defp valid_message?(%{"role" => role, "content" => [%{"type" => type, "text" => text}]})
       when is_binary(text) do
    (role in ["developer", "user"] and type == "input_text") or
      (role == "assistant" and type in ["text", "output_text"])
  end

  defp valid_message?(_message), do: false
end
