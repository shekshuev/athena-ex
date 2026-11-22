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
             :body,
             :render_prompt_as_image
           ]}

  @type t :: %__MODULE__{
          max_files: integer() | nil,
          body: map() | nil,
          render_prompt_as_image: boolean()
        }

  embedded_schema do
    field :max_files, :integer, default: 1
    field :body, :map
    field :render_prompt_as_image, :boolean, default: false
  end

  @doc false
  def changeset(file_assignment, attrs) do
    file_assignment
    |> cast(attrs, [:max_files, :body, :render_prompt_as_image])
    |> validate_required([:max_files])
    |> validate_number(:max_files, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
  end
end
