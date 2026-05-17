defmodule Athena.Execution do
  @moduledoc """
  Public API for the Execution context.

  Delegates read operations to specialized internal modules.
  """

  alias Athena.Execution.Verifier

  defdelegate verify(code, challenge, box_id), to: Verifier
end
