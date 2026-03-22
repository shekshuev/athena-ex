defmodule Athena.Content.CompletionRule do
  @moduledoc """
  Embedded schema defining how a student progresses past a specific block.
  """
  use Ecto.Schema
  import Ecto.Changeset
  use Gettext, backend: AthenaWeb.Gettext

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: [:none, :button, :submit, :pass_auto_grade], default: :none
    field :button_text, :string
    field :min_score, :integer
  end

  @doc false
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:type, :button_text, :min_score])
    |> validate_required([:type])
    |> validate_type_requirements()
  end

  defp validate_type_requirements(changeset) do
    case get_field(changeset, :type) do
      :button ->
        validate_required(changeset, [:button_text],
          message: dgettext_noop("errors", "can't be blank for button type")
        )

      :pass_auto_grade ->
        changeset
        |> validate_required([:min_score],
          message: dgettext_noop("errors", "can't be blank for auto-grade")
        )
        |> validate_number(:min_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)

      _ ->
        changeset
        |> put_change(:button_text, nil)
        |> put_change(:min_score, nil)
    end
  end
end
