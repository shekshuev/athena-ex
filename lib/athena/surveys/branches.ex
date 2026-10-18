defmodule Athena.Surveys.Branches do
  @moduledoc """
  Internal business logic for branch rules.

  Rules are kept per question and evaluated in `position` order, first match
  wins. Graph-level validity (forward-only targets, no cycles, no unreachable
  questions) belongs to `Athena.Surveys.Flow.validate_graph/1`, not here - a
  rule that is perfectly valid on its own can still create a cycle, so it can
  only be judged against the whole survey.
  """

  import Ecto.Query

  alias Athena.Repo
  alias Athena.Surveys.{Positions, Survey, SurveyBranch, SurveyQuestion}

  @doc "Lists every rule of a survey, in evaluation order."
  @spec list_branches(binary()) :: [SurveyBranch.t()]
  def list_branches(survey_id) do
    SurveyBranch
    |> where([b], b.survey_id == ^survey_id)
    |> order_by([b], asc: b.question_id, asc: b.position)
    |> Repo.all()
  end

  @doc """
  The rules attached to one question, in evaluation order. This is the hot
  path during a run: `Flow` asks only for the question it just answered.
  """
  @spec list_for_question(binary()) :: [SurveyBranch.t()]
  def list_for_question(question_id) do
    SurveyBranch
    |> where([b], b.question_id == ^question_id)
    |> order_by([b], asc: b.position)
    |> Repo.all()
  end

  @doc "Groups a survey's rules by the question they hang off."
  @spec branches_by_question(binary()) :: %{binary() => [SurveyBranch.t()]}
  def branches_by_question(survey_id) do
    survey_id
    |> list_branches()
    |> Enum.group_by(& &1.question_id)
  end

  @doc "Fetches one rule. Returns `nil` if missing."
  @spec get_branch(binary()) :: SurveyBranch.t() | nil
  def get_branch(id), do: Repo.get(SurveyBranch, id)

  @doc """
  Adds a rule to a question, appended last so it acts as the fallback for
  anything the rules above it did not match.

  Refuses on an `:all_at_once` survey: every question is on screen at once
  there, so a rule that hides or jumps past one has nowhere to act. The
  author has to choose paging first, which is a clearer failure than a rule
  that is silently never evaluated.
  """
  @spec add_branch(Survey.t(), SurveyQuestion.t(), map()) ::
          {:ok, SurveyBranch.t()} | {:error, :all_at_once | Ecto.Changeset.t()}
  def add_branch(%Survey{} = survey, %SurveyQuestion{} = question, attrs) do
    if all_at_once?(survey) do
      {:error, :all_at_once}
    else
      attrs =
        %{
          "survey_id" => survey.id,
          "question_id" => question.id,
          "position" => next_position(question.id)
        }
        |> Map.merge(normalize(attrs))

      %SurveyBranch{}
      |> SurveyBranch.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Updates a rule. Its survey and owning question are not movable."
  @spec update_branch(SurveyBranch.t(), map()) ::
          {:ok, SurveyBranch.t()} | {:error, Ecto.Changeset.t()}
  def update_branch(%SurveyBranch{} = branch, attrs) do
    attrs =
      attrs
      |> normalize()
      |> Map.drop(["survey_id", "question_id", "position"])

    branch
    |> SurveyBranch.changeset(attrs)
    |> Repo.update()
  end

  @doc "Changeset for the rule editor form."
  @spec change_branch(SurveyBranch.t(), map()) :: Ecto.Changeset.t()
  def change_branch(%SurveyBranch{} = branch, attrs \\ %{}),
    do: SurveyBranch.changeset(branch, normalize(attrs))

  @doc "Deletes a rule and closes the gap in its question's ordering."
  @spec delete_branch(SurveyBranch.t()) :: {:ok, SurveyBranch.t()} | {:error, any()}
  def delete_branch(%SurveyBranch{} = branch) do
    Repo.transaction(fn ->
      case Repo.delete(branch) do
        {:ok, deleted} ->
          renumber(branch.question_id)
          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Reorders a question's rules. Order is the whole semantics here - the first
  matching rule wins - so this is how an author puts a specific rule ahead of
  a catch-all.
  """
  @spec reorder_branches(binary(), [binary()]) :: {:ok, [SurveyBranch.t()]} | {:error, any()}
  def reorder_branches(question_id, ordered_ids) do
    Repo.transaction(fn ->
      existing = list_for_question(question_id)
      by_id = Map.new(existing, &{&1.id, &1})

      ordered = ordered_ids |> Enum.uniq() |> Enum.filter(&Map.has_key?(by_id, &1))
      remaining = Enum.reject(existing, &(&1.id in ordered))

      Positions.apply_order(Enum.map(ordered, &Map.fetch!(by_id, &1)) ++ remaining)

      list_for_question(question_id)
    end)
  end

  @doc "Whether a survey has any branching at all."
  @spec any_branches?(Survey.t() | binary()) :: boolean()
  def any_branches?(%Survey{id: id}), do: any_branches?(id)

  def any_branches?(survey_id) when is_binary(survey_id) do
    SurveyBranch
    |> where([b], b.survey_id == ^survey_id)
    |> Repo.exists?()
  end

  defp all_at_once?(%Survey{settings: %{pagination: :all_at_once}}), do: true
  defp all_at_once?(_survey), do: false

  defp next_position(question_id) do
    SurveyBranch
    |> where([b], b.question_id == ^question_id)
    |> Repo.aggregate(:count)
  end

  defp renumber(question_id),
    do: question_id |> list_for_question() |> Positions.apply_order()

  defp normalize(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
