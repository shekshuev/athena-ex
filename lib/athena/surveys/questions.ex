defmodule Athena.Surveys.Questions do
  @moduledoc """
  Internal business logic for survey questions: add, edit, delete and
  reorder.

  Ordering uses dense integers renumbered inside a transaction rather than
  `Athena.Content.Blocks`' gap-of-1024 scheme. A survey is a short, flat list
  edited by one author at a time, and branch rules address questions by id,
  not by position - so the renumber is a handful of rows, and dense positions
  keep `Flow`'s "the next question is position + 1" trivially correct.
  """

  import Ecto.Query

  alias Athena.Repo
  alias Athena.Surveys.{Positions, QuestionTypes, Survey, SurveyBranch, SurveyQuestion}

  @doc "Lists a survey's questions in `position` order."
  @spec list_questions(binary()) :: [SurveyQuestion.t()]
  def list_questions(survey_id) do
    SurveyQuestion
    |> where([q], q.survey_id == ^survey_id)
    |> order_by([q], asc: q.position, asc: q.inserted_at)
    |> Repo.all()
  end

  @doc "Fetches one question. Returns `nil` if missing."
  @spec get_question(binary()) :: SurveyQuestion.t() | nil
  def get_question(id), do: Repo.get(SurveyQuestion, id)

  @doc """
  Appends a question of `type` to a survey, pre-filled with
  `QuestionTypes.default_config/1` so a new card is immediately valid and
  answerable rather than an error until the author finishes it.
  """
  @spec add_question(Survey.t(), QuestionTypes.t(), map()) ::
          {:ok, SurveyQuestion.t()} | {:error, Ecto.Changeset.t()}
  def add_question(%Survey{} = survey, type, attrs \\ %{}) do
    attrs =
      %{
        "survey_id" => survey.id,
        "type" => type,
        "position" => next_position(survey.id),
        "page" => last_page(survey.id),
        "body" => empty_body(),
        "config" => QuestionTypes.default_config(type)
      }
      |> Map.merge(normalize(attrs))

    %SurveyQuestion{}
    |> SurveyQuestion.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a question. `survey_id` and `position` are not updatable here -
  moving a question between surveys is not a thing, and reordering goes
  through `reorder_questions/2` so positions stay dense.
  """
  @spec update_question(SurveyQuestion.t(), map()) ::
          {:ok, SurveyQuestion.t()} | {:error, Ecto.Changeset.t()}
  def update_question(%SurveyQuestion{} = question, attrs) do
    attrs =
      attrs
      |> normalize()
      |> Map.drop(["survey_id", "position"])

    question
    |> SurveyQuestion.changeset(attrs)
    |> Repo.update()
  end

  @doc "Changeset for the question editor form."
  @spec change_question(SurveyQuestion.t(), map()) :: Ecto.Changeset.t()
  def change_question(%SurveyQuestion{} = question, attrs \\ %{}),
    do: SurveyQuestion.changeset(question, normalize(attrs))

  @doc """
  Changes a question's type, replacing its config with the new type's
  defaults.

  The old config is dropped rather than merged: the field sets barely overlap,
  and a half-migrated config (a scale's `min`/`max` left on a choice question)
  is worse than a clean default. Any branch rule whose clauses test this
  question is deleted in the same transaction - a rule comparing a choice id
  against what is now a number can never match, and leaving it in place would
  silently dead-end respondents.
  """
  @spec change_question_type(SurveyQuestion.t(), QuestionTypes.t()) ::
          {:ok, SurveyQuestion.t()} | {:error, any()}
  def change_question_type(%SurveyQuestion{} = question, type) do
    Repo.transaction(fn ->
      delete_rules_referencing(question)

      result =
        question
        |> SurveyQuestion.changeset(%{
          "type" => type,
          "config" => QuestionTypes.default_config(type)
        })
        |> Repo.update()

      case result do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Deletes a question and renumbers the rest so positions stay dense.

  Its own rules go with it by cascade; rules *targeting* it are deleted here,
  since a `goto_question` pointing at a deleted row would strand the
  respondent.
  """
  @spec delete_question(SurveyQuestion.t()) :: {:ok, SurveyQuestion.t()} | {:error, any()}
  def delete_question(%SurveyQuestion{} = question) do
    Repo.transaction(fn ->
      delete_rules_referencing(question)

      case Repo.delete(question) do
        {:ok, deleted} ->
          renumber(question.survey_id)
          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Duplicates a question immediately after the original, with fresh option and
  row ids so the copy's answers and branch rules can never be confused with
  the original's.
  """
  @spec duplicate_question(SurveyQuestion.t()) ::
          {:ok, SurveyQuestion.t()} | {:error, any()}
  def duplicate_question(%SurveyQuestion{} = question) do
    Repo.transaction(fn ->
      result =
        %SurveyQuestion{}
        |> SurveyQuestion.changeset(%{
          "survey_id" => question.survey_id,
          "type" => question.type,
          "body" => question.body,
          "help_text" => question.help_text,
          "required" => question.required,
          "page" => question.page,
          "position" => question.position + 1,
          "config" => regenerate_ids(question.config)
        })
        |> Repo.insert()

      case result do
        {:ok, inserted} ->
          shift_down(question.survey_id, question.position + 1, inserted.id)
          renumber(question.survey_id)
          Repo.reload!(inserted)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Applies a new order, given the question ids in their intended sequence.

  Ids not belonging to `survey_id` are ignored, and any question the caller
  left out keeps its relative place at the end - a stale drag event from a
  browser that had not seen a just-added question must not delete that
  question's position.
  """
  @spec reorder_questions(binary(), [binary()]) :: {:ok, [SurveyQuestion.t()]} | {:error, any()}
  def reorder_questions(survey_id, ordered_ids) do
    Repo.transaction(fn ->
      existing = list_questions(survey_id)
      by_id = Map.new(existing, &{&1.id, &1})

      ordered = ordered_ids |> Enum.uniq() |> Enum.filter(&Map.has_key?(by_id, &1))
      remaining = Enum.reject(existing, &(&1.id in ordered))

      Positions.apply_order(Enum.map(ordered, &Map.fetch!(by_id, &1)) ++ remaining)

      list_questions(survey_id)
    end)
  end

  defp shift_down(survey_id, from_position, except_id) do
    SurveyQuestion
    |> where([q], q.survey_id == ^survey_id)
    |> where([q], q.position >= ^from_position)
    |> where([q], q.id != ^except_id)
    |> Repo.update_all(inc: [position: 1])
  end

  defp renumber(survey_id), do: survey_id |> list_questions() |> Positions.apply_order()

  # A rule is invalidated both by its owning question disappearing (handled by
  # the FK cascade) and by any of its *clauses* referencing it, which the
  # database cannot see because clauses live inside the condition's jsonb.
  defp delete_rules_referencing(%SurveyQuestion{id: id, survey_id: survey_id}) do
    SurveyBranch
    |> where([b], b.survey_id == ^survey_id)
    |> Repo.all()
    |> Enum.filter(&references_question?(&1, id))
    |> Enum.each(&Repo.delete!/1)
  end

  defp references_question?(%SurveyBranch{} = branch, question_id) do
    branch.target_question_id == question_id or
      Enum.any?((branch.condition && branch.condition.clauses) || [], fn clause ->
        clause.question_id == question_id
      end)
  end

  defp regenerate_ids(config) when is_map(config) do
    Enum.reduce(["options", "items", "rows", "pairs"], config, fn key, acc ->
      case Map.get(acc, key) do
        list when is_list(list) ->
          Map.put(acc, key, Enum.map(list, &Map.put(&1, "id", Ecto.UUID.generate())))

        _ ->
          acc
      end
    end)
  end

  defp regenerate_ids(config), do: config

  defp next_position(survey_id) do
    SurveyQuestion
    |> where([q], q.survey_id == ^survey_id)
    |> Repo.aggregate(:count)
  end

  defp last_page(survey_id) do
    SurveyQuestion
    |> where([q], q.survey_id == ^survey_id)
    |> Repo.aggregate(:max, :page)
    |> Kernel.||(0)
  end

  # TipTap's representation of an empty document - the builder's rich-text
  # editor needs a well-formed doc to mount into, not `nil`.
  defp empty_body, do: %{"type" => "doc", "content" => []}

  defp normalize(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
