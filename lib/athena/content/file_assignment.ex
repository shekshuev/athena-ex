defmodule Athena.Content.FileAssignment do
  @moduledoc """
  Represents the content structure for a :file_assignment block.

  This embed schema validates the configuration for file submission assignments,
  including description, max files allowed, and allowed file extensions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :max_files,
             :body
           ]}

  @type t :: %__MODULE__{
          max_files: integer() | nil,
          body: map() | nil
        }

  embedded_schema do
    field :max_files, :integer, default: 1
    field :body, :map
  end

  @doc false
  def changeset(file_assignment, attrs) do
    file_assignment
    |> cast(attrs, [:max_files, :body])
    |> validate_required([:max_files])
    |> validate_number(:max_files, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
  end
end
