defmodule Athena.Surveys.SurveyQuestion do
  @moduledoc """
  One question of a survey.

  `body` is a TipTap/ProseMirror JSON document (the rich prompt); `config` is
  a plain jsonb map validated through the per-type embedded schema in
  `Athena.Surveys.QuestionTypes` and then round-tripped through JSON, exactly
  as `Athena.Content.Block` does for its `content`. So **`config` is always
  string-keyed downstream** - the embedded schemas are validation-only, and
  nothing reads them back as structs at render time.

  `position` orders questions within the survey and `page` groups them into
  Google-Forms-style sections (page `0` is the first page). `position` is
  deliberately *not* uniquely indexed: a reorder swaps many rows at once and a
  unique index would make every intermediate state a constraint violation.
  `Athena.Surveys.Questions` renumbers gaplessly inside a transaction instead.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Surveys.{QuestionTypes, Survey}
  alias Athena.Content.Tiptap

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "survey_questions" do
    field :position, :integer, default: 0
    field :page, :integer, default: 0
    field :type, Ecto.Enum, values: QuestionTypes.all()
    field :body, :map
    field :help_text, :string
    field :required, :boolean, default: false
    field :config, :map, default: %{}

    belongs_to :survey, Survey

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(question, attrs) do
    question
    |> cast(attrs, [:position, :page, :type, :body, :help_text, :required, :config, :survey_id])
    |> update_change(:body, &Tiptap.strip_colors/1)
    |> validate_required([:type, :body, :survey_id])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:page, greater_than_or_equal_to: 0)
    |> validate_length(:help_text, max: 500)
    |> foreign_key_constraint(:survey_id)
    |> validate_config_by_type()
  end

  # Mirrors `Athena.Content.Block.validate_content_by_type/1`: validate the
  # type-specific map through its embedded schema, then write back the
  # JSON-round-tripped result so the stored config has string keys and no
  # struct residue.
  defp validate_config_by_type(changeset) do
    case get_field(changeset, :type) do
      nil ->
        changeset

      type ->
        type
        |> QuestionTypes.config_changeset(get_field(changeset, :config) || %{})
        |> apply_config_changes(changeset)
    end
  end

  defp apply_config_changes(%Ecto.Changeset{valid?: true} = config_cs, changeset) do
    pure_string_map =
      config_cs
      |> Ecto.Changeset.apply_changes()
      |> Jason.encode!()
      |> Jason.decode!()

    put_change(changeset, :config, pure_string_map)
  end

  # Note the divergence from `Block`, which reduces over `config_cs.errors`
  # alone. With `cast_embed`, a child's errors live in `changes`, not in
  # `errors` - so for an invalid option or matrix row that reduce iterates an
  # empty list, adds nothing, and lets an invalid config save. Traversing
  # catches the nested ones, and the flattened path (`options.0.text`) is what
  # the builder needs to mark the right field on the right card.
  defp apply_config_changes(%Ecto.Changeset{valid?: false} = config_cs, changeset) do
    config_cs
    |> Ecto.Changeset.traverse_errors(& &1)
    |> flatten_errors()
    |> Enum.reduce(changeset, fn {path, {msg, opts}}, acc ->
      add_error(acc, :config, "#{path}: #{msg}", opts)
    end)
  end

  defp flatten_errors(errors, prefix \\ [])

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {field, nested} -> flatten_errors(nested, prefix ++ [field]) end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    errors
    |> Enum.with_index()
    |> Enum.flat_map(fn
      # A leaf: the {message, opts} tuple Ecto stores for a field's error.
      {{msg, opts}, _index} when is_binary(msg) and is_list(opts) ->
        [{Enum.join(prefix, "."), {msg, opts}}]

      # An `embeds_many` child; valid children traverse to `%{}` and drop out.
      {nested, index} ->
        flatten_errors(nested, prefix ++ [index])
    end)
  end
end
