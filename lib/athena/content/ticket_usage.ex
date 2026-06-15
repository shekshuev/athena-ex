defmodule Athena.Content.TicketUsage do
  @moduledoc """
  A struct representing the usage statistics of library blocks.
  Passed from the Learning context to Content to balance ticket generation.
  """

  @type t :: %__MODULE__{
          counts: %{String.t() => integer()}
        }

  defstruct counts: %{}

  @doc "Creates a new TicketUsage struct from a raw map."
  @spec new(%{String.t() => integer()}) :: t()
  def new(counts \\ %{}) do
    %__MODULE__{counts: counts}
  end
end
