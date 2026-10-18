defmodule Parlora.AdapterInit do
  @moduledoc "Identity, event destination, agreed format, and limits supplied to an adapter."
  @type t :: %__MODULE__{
          session_id: String.t(),
          adapter_id: String.t(),
          generation: non_neg_integer(),
          event_sink: pid(),
          audio_format: Parlora.AudioFormat.t() | nil,
          limits: Parlora.Limits.t()
        }
  @enforce_keys [:session_id, :adapter_id, :generation, :event_sink, :limits]
  defstruct [:session_id, :adapter_id, :generation, :event_sink, :audio_format, :limits]
end
