defmodule BookingDesk.Consent do
  @moduledoc "A conservative lexical veto; semantic intent and current verified state are still required."

  def unconditional?(text) do
    text = String.replace(text, "’", "'")

    not String.contains?(text, "?") and
      not Regex.match?(
        ~r/\b(no|not|don't|cannot|can't|won't|isn't|wasn't|wrong|incorrect|unless|if|maybe|perhaps|wait|instead|but|except|stop)\b/i,
        text
      )
  end
end
