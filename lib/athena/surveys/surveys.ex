defmodule Athena.Surveys.Surveys do
  @moduledoc """
  Internal business logic for survey records themselves - CRUD, the
  `:draft -> :published -> :closed -> :archived` lifecycle, and the
  duplicate-as-new-version flow.
  """

  import Ecto.Query

  alias Athena.Identity
  alias Athena.Identity.Acl
  alias Athena.Repo
  alias Athena.Surveys.{Survey, SurveyBranch, SurveyQuestion, SurveyResponse}

  @doc """
  Flop-paginated list of the surveys `user` may read, scoped through
  `Acl.scope_query/3` so a role holding `surveys.read` with the `own_only`
  policy sees only its own.
  """
  @spec list_for_user(map(), map()) ::
          {:ok, {[Survey.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_user(user, params \\ %{}) do
    from(s in Survey)
    |> Acl.scope_query(user, "surveys.read")
    |> Flop.validate_and_run(params, for: Survey)
  end

  @doc "Fetches a survey without its questions. Returns `nil` if missing."
  @spec get_survey(binary()) :: Survey.t() | nil
  def get_survey(id), do: Repo.get(Survey, id)

  @doc "Fetches a survey with its questions preloaded in `position` order."
  @spec get_survey_with_questions(binary()) :: Survey.t() | nil
  def get_survey_with_questions(id) do
    Survey
    |> Repo.get(id)
    |> case do
      nil -> nil
      survey -> Repo.preload(survey, :questions)
    end
  end

  @doc """
  Creates a survey owned by `user`. `owner_id` is set from `user`, not cast
  from the attrs - ownership decides `own_only` access, so it must never come
  from the form.
  """
  @spec create_survey(map(), map()) :: {:ok, Survey.t()} | {:error, Ecto.Changeset.t()}
  def create_survey(user, attrs) do
    %Survey{}
    |> Survey.changeset(Map.put(normalize(attrs), "owner_id", user.id))
    |> Repo.insert()
  end

  @doc """
  Updates a survey's own attributes. Its questions are *not* touched here, and
  `editable?/1` governs whether they may change at all.
  """
  @spec update_survey(Survey.t(), map()) :: {:ok, Survey.t()} | {:error, Ecto.Changeset.t()}
  def update_survey(%Survey{} = survey, attrs) do
    survey
    |> Survey.changeset(Map.delete(normalize(attrs), "owner_id"))
    |> Repo.update()
  end

  @doc "Changeset for the survey settings form."
  @spec change_survey(Survey.t(), map()) :: Ecto.Changeset.t()
  def change_survey(%Survey{} = survey, attrs \\ %{}),
    do: Survey.changeset(survey, normalize(attrs))

  @doc """
  Whether a survey's *questions and logic* may still be edited.

  Editing the questions of a survey people have already answered silently
  changes what those answers mean - rewording a scale's poles, or dropping an
  option, makes the collected data incomparable with itself. So once any
  response exists the structure locks and the builder offers
  `duplicate_as_version/2` instead. The survey's own title, description and
  settings stay editable.
  """
  @spec editable?(Survey.t()) :: boolean()
  def editable?(%Survey{} = survey), do: not has_responses?(survey)

  @doc "Whether any response - even an unfinished one - exists for this survey."
  @spec has_responses?(Survey.t() | binary()) :: boolean()
  def has_responses?(%Survey{id: id}), do: has_responses?(id)

  def has_responses?(survey_id) when is_binary(survey_id) do
    SurveyResponse
    |> where([r], r.survey_id == ^survey_id)
    |> Repo.exists?()
  end

  @doc """
  Publishes a survey, making it answerable. A survey with no questions cannot
  be published - there would be nothing to answer, and the player would render
  an empty card.
  """
  @spec publish(Survey.t()) :: {:ok, Survey.t()} | {:error, Ecto.Changeset.t() | atom()}
  def publish(%Survey{} = survey) do
    if question_count(survey) == 0 do
      {:error, :no_questions}
    else
      survey
      |> Ecto.Changeset.change(%{status: :published, published_at: now()})
      |> Repo.update()
    end
  end

  @doc "Closes a survey to new responses, leaving its results readable."
  @spec close(Survey.t()) :: {:ok, Survey.t()} | {:error, Ecto.Changeset.t()}
  def close(%Survey{} = survey) do
    survey
    |> Ecto.Changeset.change(%{status: :closed, closed_at: now()})
    |> Repo.update()
  end

  @doc "Reopens a closed survey."
  @spec reopen(Survey.t()) :: {:ok, Survey.t()} | {:error, Ecto.Changeset.t()}
  def reopen(%Survey{} = survey) do
    survey
    |> Ecto.Changeset.change(%{status: :published, closed_at: nil})
    |> Repo.update()
  end

  @doc """
  Hard-deletes a survey, and with it every question, rule, response and
  answer (the schema cascades).

  Refuses when any response exists: that data cannot be reconstructed and is
  usually the only record of what students said. Close such a survey instead,
  or take a fresh copy with `duplicate_as_version/2`.
  """
  @spec delete_survey(Survey.t()) ::
          {:ok, Survey.t()} | {:error, :has_responses | Ecto.Changeset.t()}
  def delete_survey(%Survey{} = survey) do
    if has_responses?(survey) do
      {:error, :has_responses}
    else
      Repo.delete(survey)
    end
  end

  @doc """
  Copies a survey's questions and branch rules into a new `:draft` owned by
  `user`, linked back through `source_survey_id`. This is how a locked,
  already-answered survey is changed: the original keeps its responses intact
  and comparable, and the copy is a clean instrument.

  Question and rule ids are regenerated, and rule targets are remapped onto
  the new ids - a copy that pointed at the original's questions would branch
  into another survey's rows.
  """
  @spec duplicate_as_version(Survey.t(), map()) ::
          {:ok, Survey.t()} | {:error, any()}
  def duplicate_as_version(%Survey{} = survey, user) do
    Repo.transaction(fn ->
      with {:ok, copy} <- insert_copy(survey, user),
           {:ok, id_map} <- copy_questions(survey, copy),
           :ok <- copy_branches(survey, copy, id_map) do
        copy
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_copy(survey, user) do
    %Survey{}
    |> Survey.changeset(%{
      "title" => "#{survey.title} (copy)",
      "description" => survey.description,
      "owner_id" => user.id,
      "source_survey_id" => survey.id,
      "settings" => Map.from_struct(survey.settings || %{})
    })
    |> Repo.insert()
  end

  defp copy_questions(survey, copy) do
    questions =
      SurveyQuestion
      |> where([q], q.survey_id == ^survey.id)
      |> order_by([q], asc: q.position)
      |> Repo.all()

    Enum.reduce_while(questions, {:ok, %{}}, fn question, {:ok, id_map} ->
      attrs = %{
        "survey_id" => copy.id,
        "position" => question.position,
        "page" => question.page,
        "type" => question.type,
        "body" => question.body,
        "help_text" => question.help_text,
        "required" => question.required,
        "config" => question.config
      }

      case %SurveyQuestion{} |> SurveyQuestion.changeset(attrs) |> Repo.insert() do
        {:ok, inserted} -> {:cont, {:ok, Map.put(id_map, question.id, inserted.id)}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp copy_branches(survey, copy, id_map) do
    branches =
      SurveyBranch
      |> where([b], b.survey_id == ^survey.id)
      |> Repo.all()

    Enum.reduce_while(branches, :ok, fn branch, :ok ->
      attrs = %{
        "survey_id" => copy.id,
        "question_id" => Map.fetch!(id_map, branch.question_id),
        "position" => branch.position,
        "action" => branch.action,
        "target_question_id" => remap_target(branch.target_question_id, id_map),
        "target_page" => branch.target_page,
        "condition" => remap_condition(branch.condition, id_map)
      }

      case %SurveyBranch{} |> SurveyBranch.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp remap_target(nil, _id_map), do: nil
  defp remap_target(id, id_map), do: Map.get(id_map, id)

  defp remap_condition(nil, _id_map), do: nil

  defp remap_condition(condition, id_map) do
    clauses =
      Enum.map(condition.clauses || [], fn clause ->
        %{
          "question_id" => Map.get(id_map, clause.question_id),
          "op" => clause.op,
          "value" => clause.value
        }
      end)

    %{"logic" => condition.logic, "clauses" => clauses}
  end

  @doc "Number of questions in a survey."
  @spec question_count(Survey.t() | binary()) :: non_neg_integer()
  def question_count(%Survey{id: id}), do: question_count(id)

  def question_count(survey_id) when is_binary(survey_id) do
    SurveyQuestion
    |> where([q], q.survey_id == ^survey_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Response counts for many surveys at once, as `%{survey_id => count}`.

  A list screen showing a count per row would otherwise be N+1, and the
  count is also what decides whether the row offers "Edit" or "Open" - so it
  is needed for every row, not just on demand.
  """
  @spec count_responses_for([binary()]) :: %{binary() => non_neg_integer()}
  def count_responses_for([]), do: %{}

  def count_responses_for(survey_ids) do
    SurveyResponse
    |> where([r], r.survey_id in ^survey_ids)
    |> group_by([r], r.survey_id)
    |> select([r], {r.survey_id, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Question counts for many surveys at once, as `%{survey_id => count}`."
  @spec count_questions_for([binary()]) :: %{binary() => non_neg_integer()}
  def count_questions_for([]), do: %{}

  def count_questions_for(survey_ids) do
    SurveyQuestion
    |> where([q], q.survey_id in ^survey_ids)
    |> group_by([q], q.survey_id)
    |> select([q], {q.survey_id, count(q.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Whether `user` may manage this specific survey - the permission *and* the
  record-level `own_only` policy, so a non-owner holding `surveys.update` with
  that policy is refused on someone else's survey rather than only being
  kept off the screen.
  """
  @spec can_manage?(map(), Survey.t()) :: boolean()
  def can_manage?(user, %Survey{} = survey),
    do: Identity.can?(user, "surveys.update", survey)

  defp normalize(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
