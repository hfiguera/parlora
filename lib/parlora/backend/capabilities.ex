defmodule Parlora.Backend.Capabilities do
  @moduledoc "Features supported by the configured backend mapping."
  @type t :: %__MODULE__{
          updates?: boolean(),
          cancellation: :unsupported | :advisory,
          progress?: boolean(),
          clarification?: boolean()
        }
  defstruct updates?: false, cancellation: :unsupported, progress?: false, clarification?: false
end
