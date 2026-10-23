defmodule Athena.Surveys.SurveysTest do
  @moduledoc """
  The survey record: lifecycle, the structural lock once responses exist, and
  duplicate-as-version.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys
  alias Athena.Surveys.{Survey, SurveyBranch, SurveyQuestion}

  defp owner, do: insert(:account, role: insert(:role, permissions: ["surveys.read"]))

  describe "creation" do
    test "ownership comes from the user, never from the form" do
      user = owner()
      impostor = Ecto.UUID.generate()

      {:ok, survey} =
        Surveys.create_survey(user, %{"title" => "Mid-course feedback", "owner_id" => impostor})

      assert survey.owner_id == user.id
    end

    test "a survey starts as a draft with default settings filled in" do
      {:ok, survey} = Surveys.create_survey(owner(), %{"title" => "Feedback"})

      assert survey.status == :draft
      assert survey.settings.pagination == :one_per_page
      assert survey.settings.show_progress
      assert survey.settings.allow_back
    end

    test "a title is required" do
      assert {:error, changeset} = Surveys.create_survey(owner(), %{})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "updating cannot transfer ownership" do
      user = owner()
      {:ok, survey} = Surveys.create_survey(user, %{"title" => "Feedback"})

      {:ok, updated} =
        Surveys.update_survey(survey, %{
          "title" => "Renamed",
          "owner_id" => Ecto.UUID.generate()
        })

      assert updated.title == "Renamed"
      assert updated.owner_id == user.id
    end
  end

  describe "publishing" do
    test "a survey with no questions cannot be published" do
      survey = insert(:survey)

      assert {:error, :no_questions} = Surveys.publish_survey(survey)
    end

    test "publishing stamps published_at" do
      survey = insert(:survey)
      insert(:survey_question, survey: survey)

      assert {:ok, published} = Surveys.publish_survey(survey)
      assert published.status == :published
      assert published.published_at
    end

    test "closing and reopening round-trip" do
      survey = insert(:survey, status: :published)

      {:ok, closed} = Surveys.close_survey(survey)
      assert closed.status == :closed
      assert closed.closed_at

      {:ok, reopened} = Surveys.reopen_survey(closed)
      assert reopened.status == :published
      assert reopened.closed_at == nil
    end
  end

  describe "the structural lock" do
    test "questions stay editable while nobody has answered" do
      survey = insert(:survey, status: :published)
      insert(:survey_question, survey: survey)

      assert Surveys.survey_editable?(survey)
    end

    test "a single partial response locks the structure" do
      survey = insert(:survey, status: :published)
      insert(:survey_question, survey: survey)
      insert(:survey_response, survey: survey, status: :in_progress)

      refute Surveys.survey_editable?(survey)
      assert Surveys.survey_has_responses?(survey)
    end
  end

  describe "deletion" do
    test "a survey with responses refuses to be deleted" do
      survey = insert(:survey)
      insert(:survey_response, survey: survey)

      assert {:error, :has_responses} = Surveys.delete_survey(survey)
      assert Repo.get(Survey, survey.id)
    end

    test "an unanswered survey deletes, taking its questions and rules with it" do
      survey = insert(:survey)
      question = insert(:survey_question, survey: survey)
      insert(:survey_branch, survey: survey, question: question)

      assert {:ok, _} = Surveys.delete_survey(survey)
      assert Repo.aggregate(SurveyQuestion, :count) == 0
      assert Repo.aggregate(SurveyBranch, :count) == 0
    end

    test "refuses to delete a survey that already has responses" do
      user = owner()
      survey = insert(:survey, owner_id: user.id, status: :published)
      insert(:survey_response, survey: survey)

      assert {:error, :has_responses} = Surveys.delete_survey(survey)
      assert Surveys.get_survey(survey.id)

      {:ok, {listed, _meta}} = Surveys.list_surveys_for_user(user)
      assert Enum.any?(listed, &(&1.id == survey.id))
    end
  end

  describe "duplicate_as_version/2" do
    setup do
      user = owner()
      survey = insert(:survey, owner_id: user.id, status: :published)

      {config, [low, high]} = choice_config(["Too slow", "Too fast"])

      q1 =
        insert(:survey_question,
          survey: survey,
          type: :single_choice,
          config: config,
          position: 0
        )

      q2 = insert(:survey_question, survey: survey, type: :scale, position: 1)

      {:ok, branch} =
        Surveys.add_branch(survey, q1, %{
          "action" => "goto_question",
          "target_question_id" => q2.id,
          "condition" => %{
            "logic" => "and",
            "clauses" => [
              %{"question_id" => q1.id, "op" => "eq", "value" => %{"choice_ids" => [low]}}
            ]
          }
        })

      %{user: user, survey: survey, q1: q1, q2: q2, branch: branch, low: low, high: high}
    end

    test "copies questions in order with fresh ids", ctx do
      {:ok, copy} = Surveys.duplicate_as_version(ctx.survey, ctx.user)

      assert copy.status == :draft
      assert copy.source_survey_id == ctx.survey.id

      copied = Surveys.list_questions(copy.id)
      assert length(copied) == 2
      assert Enum.map(copied, & &1.type) == [:single_choice, :scale]
      assert Enum.map(copied, & &1.position) == [0, 1]

      original_ids = [ctx.q1.id, ctx.q2.id]
      refute Enum.any?(copied, &(&1.id in original_ids))
    end

    test "remaps rule targets and clauses onto the copy's own questions", ctx do
      {:ok, copy} = Surveys.duplicate_as_version(ctx.survey, ctx.user)

      [copied_q1, copied_q2] = Surveys.list_questions(copy.id)
      assert [copied_branch] = Surveys.list_branches(copy.id)

      # A copy still pointing at the original's rows would branch into another
      # survey - the whole reason the remap exists.
      assert copied_branch.question_id == copied_q1.id
      assert copied_branch.target_question_id == copied_q2.id
      assert [clause] = copied_branch.condition.clauses
      assert clause.question_id == copied_q1.id
      refute clause.question_id == ctx.q1.id
    end

    test "the original keeps its responses and stays locked", ctx do
      insert(:survey_response, survey: ctx.survey)

      {:ok, copy} = Surveys.duplicate_as_version(ctx.survey, ctx.user)

      refute Surveys.survey_editable?(ctx.survey)
      assert Surveys.survey_editable?(copy)
      assert Surveys.list_responses(copy.id) == []
    end

    test "the copy belongs to whoever duplicated it", ctx do
      other = owner()

      {:ok, copy} = Surveys.duplicate_as_version(ctx.survey, other)

      assert copy.owner_id == other.id
    end
  end

  describe "list_for_user/3" do
    test "an own_only role sees only its own surveys" do
      role =
        insert(:role, permissions: ["surveys.read"], policies: %{"surveys.read" => ["own_only"]})

      user = insert(:account, role: role)

      mine = insert(:survey, owner_id: user.id)
      _theirs = insert(:survey, owner_id: Ecto.UUID.generate())

      {:ok, {listed, _meta}} = Surveys.list_surveys_for_user(user)

      assert Enum.map(listed, & &1.id) == [mine.id]
    end

    test "a user without the permission sees nothing" do
      user = insert(:account, role: insert(:role, permissions: []))
      insert(:survey)

      {:ok, {listed, _meta}} = Surveys.list_surveys_for_user(user)

      assert listed == []
    end
  end
end
