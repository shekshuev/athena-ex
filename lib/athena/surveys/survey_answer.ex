defmodule Athena.Surveys.SurveyAnswer do
  @moduledoc """
  One answer to one question, upserted as the respondent types or clicks.

  ## `value` and the typed projections

  `value` is the raw, type-shaped answer as jsonb. Beside it sit four
  *projections* - `value_numeric`, `value_text`, `value_choice_ids` and
  `skipped` - which exist so that `Athena.Surveys.Results` is plain SQL
  (`avg`, `stddev_samp`, `percentile_cont`, `count ... group by`,
  `unnest`) instead of decoding every respondent's JSON in Elixir.

  The projections are derived **only here, in the changeset**, from `value`
  plus the question's type, and never written by a caller. `value` is the
  single source of truth; a projection is a view of it. That is the one rule
  that keeps the two from drifting, and it is why `changeset/3` takes the
  question type as an argument rather than trusting the attrs.

  Per-type shape of `value`, and what it projects to:

      :single_choice   %{"choice_id" => id, "other_text" => str | nil}
                       -> value_choice_ids [id], value_text other_text
      :multiple_choice %{"choice_ids" => [id], "other_text" => str | nil}
                       -> value_choice_ids [ids], value_text other_text
      :dichotomous     %{"choice_id" => "yes" | "no"}
                       -> value_choice_ids [id], value_numeric 1.0 | 0.0
      :open_text       %{"text" => str}            -> value_text
      :numeric         %{"number" => number}       -> value_numeric
      :scale           %{"number" => number}       -> value_numeric
      :multi_scale     %{"row_id" => id, "number" => number}
                       -> value_numeric, and row_key is taken from row_id
      :matching        %{"pairs" => %{left_id => right_id}}  -> value only
      :ranking         %{"choice_ids" => [id, ...]} -> value_choice_ids, where
                       array *position* carries the rank
      :nps             %{"number" => 0..10}        -> value_numeric

  `value_choice_ids` is `{:array, :string}`, not `:binary_id`: the reserved
  ids (`"other"`, `"yes"`, `"no"` - see `Athena.Surveys.QuestionTypes`) are not
  UUIDs, and a typed UUID array would reject them.

  ## `row_key`

  Empty for every type but `:multi_scale`, which writes one answer row per
  matrix row. It is part of the unique index `(response_id, question_id,
  row_key)`, which is also the upsert target for autosave - so a matrix
  behaves as the battery of separate scale items it actually is, and Cronbach's
  alpha over it is a SQL query rather than JSON surgery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Surveys.{QuestionTypes, SurveyQuestion, SurveyResponse}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "survey_answers" do
    field :row_key, :string, default: ""
    field :value, :map, default: %{}
    field :value_numeric, :float
    field :value_text, :string
    field :value_choice_ids, {:array, :string}, default: []
    field :skipped, :boolean, default: false
    field :answered_at, :utc_datetime

    belongs_to :response, SurveyResponse
    belongs_to :question, SurveyQuestion

    timestamps(type: :utc_datetime)
  end

  @castable [:response_id, :question_id, :value, :skipped]

  @doc """
  Builds an answer changeset. `question_type` decides how `value` is read, so
  it is passed explicitly rather than inferred from the attrs - an answer
  whose projections were derived under the wrong type would be silently
  mis-aggregated rather than rejected.
  """
  @spec changeset(t(), map(), QuestionTypes.t()) :: Ecto.Changeset.t()
  def changeset(answer, attrs, question_type) do
    answer
    |> cast(attrs, @castable)
    |> validate_required([:response_id, :question_id])
    |> put_change(:answered_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> derive_projections(question_type)
    |> foreign_key_constraint(:response_id)
    |> foreign_key_constraint(:question_id)
    |> unique_constraint([:response_id, :question_id, :row_key],
      name: :survey_answers__response_id__question_id__row_key__uk
    )
  end

  defp derive_projections(changeset, question_type) do
    value = get_field(changeset, :value) || %{}

    if get_field(changeset, :skipped) do
      changeset
      |> put_change(:value, %{})
      |> put_change(:value_numeric, nil)
      |> put_change(:value_text, nil)
      |> put_change(:value_choice_ids, [])
      |> put_row_key(question_type, value)
    else
      changeset
      |> put_row_key(question_type, value)
      |> project(question_type, value)
    end
  end

  # `row_key` is read out of the value rather than cast from the attrs, so the
  # row an answer belongs to and the row it is indexed under cannot disagree.
  defp put_row_key(changeset, :multi_scale, value) do
    case value["row_id"] do
      row_id when is_binary(row_id) and row_id != "" ->
        put_change(changeset, :row_key, row_id)

      _ ->
        add_error(changeset, :value, "row_id: is required for a matrix question")
    end
  end

  defp put_row_key(changeset, _type, _value), do: put_change(changeset, :row_key, "")

  defp project(changeset, :single_choice, value) do
    case value["choice_id"] do
      id when is_binary(id) and id != "" ->
        changeset
        |> put_change(:value_choice_ids, [id])
        |> put_change(:value_text, other_text(value))

      _ ->
        add_error(changeset, :value, "choice_id: is required")
    end
  end

  defp project(changeset, :multiple_choice, value) do
    case value["choice_ids"] do
      ids when is_list(ids) ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
          changeset
          |> put_change(:value_choice_ids, ids)
          |> put_change(:value_text, other_text(value))
        else
          add_error(changeset, :value, "choice_ids: must all be ids")
        end

      _ ->
        add_error(changeset, :value, "choice_ids: is required")
    end
  end

  defp project(changeset, :dichotomous, value) do
    yes = QuestionTypes.yes_choice_id()
    no = QuestionTypes.no_choice_id()

    case value["choice_id"] do
      ^yes ->
        changeset
        |> put_change(:value_choice_ids, [yes])
        |> put_change(:value_numeric, 1.0)

      ^no ->
        changeset
        |> put_change(:value_choice_ids, [no])
        |> put_change(:value_numeric, 0.0)

      _ ->
        add_error(changeset, :value, "choice_id: must be #{yes} or #{no}")
    end
  end

  defp project(changeset, :open_text, value) do
    case value["text"] do
      text when is_binary(text) -> put_change(changeset, :value_text, text)
      _ -> add_error(changeset, :value, "text: is required")
    end
  end

  defp project(changeset, type, value) when type in [:numeric, :scale, :nps, :multi_scale] do
    case value["number"] do
      n when is_number(n) -> put_change(changeset, :value_numeric, n / 1)
      _ -> add_error(changeset, :value, "number: is required")
    end
  end

  defp project(changeset, :matching, value) do
    case value["pairs"] do
      pairs when is_map(pairs) -> changeset
      _ -> add_error(changeset, :value, "pairs: is required")
    end
  end

  defp project(changeset, :ranking, value) do
    case value["choice_ids"] do
      ids when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
             length(Enum.uniq(ids)) == length(ids) do
          put_change(changeset, :value_choice_ids, ids)
        else
          add_error(changeset, :value, "choice_ids: must be distinct ids")
        end

      _ ->
        add_error(changeset, :value, "choice_ids: is required")
    end
  end

  defp other_text(value) do
    case value["other_text"] do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end
end
