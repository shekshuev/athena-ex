defmodule Athena.Learning.SubmissionContent do
  @moduledoc """
  Embedded schema defining the payload of a student's submission based on the block type.
  """
  use Ecto.Schema
  import Ecto.Changeset
  use Gettext, backend: AthenaWeb.Gettext

  @primary_key false
  @derive Jason.Encoder
  embedded_schema do
    field :type, Ecto.Enum,
      values: [:text, :code, :quiz_question, :quiz_exam, :video, :image, :attachment]

    field :text_answer, :string
    field :code_language, :string
    field :file_urls, {:array, :string}, default: []
    field :selected_choices, {:array, :string}, default: []
    field :exam_answers, {:array, :map}, default: []
  end

  @doc false
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :type,
      :text_answer,
      :code_language,
      :file_urls,
      :selected_choices,
      :exam_answers
    ])
    |> validate_required([:type])
    |> validate_type_requirements()
  end

  defp validate_type_requirements(changeset) do
    type = get_field(changeset, :type)
    validate_by_type(changeset, type)
  end

  defp validate_by_type(changeset, :text) do
    changeset
    |> validate_required([:text_answer],
      message: dgettext_noop("errors", "can't be blank for text answer")
    )
    |> put_change(:code_language, nil)
    |> put_change(:file_urls, [])
    |> put_change(:selected_choices, [])
    |> put_change(:exam_answers, [])
  end

  defp validate_by_type(changeset, :code) do
    changeset
    |> validate_required([:text_answer],
      message: dgettext_noop("errors", "code cannot be empty")
    )
    |> validate_required([:code_language],
      message: dgettext_noop("errors", "language is required for code")
    )
    |> put_change(:file_urls, [])
    |> put_change(:selected_choices, [])
    |> put_change(:exam_answers, [])
  end

  defp validate_by_type(changeset, :attachment) do
    changeset
    |> validate_length(:file_urls,
      min: 1,
      message: dgettext_noop("errors", "at least one file is required")
    )
    |> put_change(:text_answer, nil)
    |> put_change(:code_language, nil)
    |> put_change(:selected_choices, [])
    |> put_change(:exam_answers, [])
  end

  defp validate_by_type(changeset, :quiz_question) do
    text = get_field(changeset, :text_answer)
    choices = get_field(changeset, :selected_choices)

    changeset =
      if (is_nil(text) or text == "") and (is_nil(choices) or choices == []) do
        add_error(
          changeset,
          :selected_choices,
          dgettext_noop("errors", "please provide an answer or select a choice")
        )
      else
        changeset
      end

    changeset
    |> put_change(:code_language, nil)
    |> put_change(:file_urls, [])
    |> put_change(:exam_answers, [])
  end

  defp validate_by_type(changeset, :quiz_exam) do
    changeset
    |> validate_length(:exam_answers,
      min: 1,
      message: dgettext_noop("errors", "exam answers cannot be empty")
    )
    |> put_change(:text_answer, nil)
    |> put_change(:code_language, nil)
    |> put_change(:file_urls, [])
    |> put_change(:selected_choices, [])
  end

  defp validate_by_type(changeset, _other_type) do
    changeset
    |> put_change(:text_answer, nil)
    |> put_change(:code_language, nil)
    |> put_change(:file_urls, [])
    |> put_change(:selected_choices, [])
    |> put_change(:exam_answers, [])
  end
end
