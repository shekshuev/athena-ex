defmodule Athena.Surveys.ResponsesTest do
  @moduledoc """
  Taking a survey: attribution, resuming, autosave and partial visibility.

  The attribution tests are the ones that matter most - `cohort_id` is what
  the results layer reads to decide whether it may show who answered, so
  getting it wrong exposes a student who was promised a group aggregate.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys
  alias Athena.Surveys.{Responses, SurveyAnswer, SurveyResponse}

  defp published_survey(attrs \\ %{}) do
    insert(:survey, Map.merge(%{status: :published}, Map.new(attrs)))
  end

  # A response always belongs to a course: that is where the cohort comes
  # from, and `get_or_start/3` refuses to create one without it. Tests that do
  # not care which course go through here.
  defp start(survey, student, course \\ nil) do
    course = course || insert(:course)

    Surveys.get_or_start_response(survey, student, %{course_id: course.id})
  end

  defp cohort_enrolled(course) do
    student = insert(:account)
    cohort = insert(:cohort)
    insert(:cohort_membership, cohort_id: cohort.id, account_id: student.id)
    insert(:enrollment, course_id: course.id, cohort_id: cohort.id, status: :active)
    {student, cohort}
  end

  defp individually_enrolled(course) do
    student = insert(:account)
    insert(:enrollment, course_id: course.id, account_id: student.id, status: :active)
    student
  end

  describe "attribution" do
    test "a student enrolled through a cohort is attributed to the cohort, not shown by name" do
      course = insert(:course)
      {student, cohort} = cohort_enrolled(course)
      survey = published_survey()

      assert {:ok, response} =
               Surveys.get_or_start_response(survey, student, %{course_id: course.id})

      assert response.cohort_id == cohort.id
      assert response.course_id == course.id
    end

    test "an individually enrolled student has no cohort to hide in" do
      course = insert(:course)
      student = individually_enrolled(course)
      survey = published_survey()

      assert {:ok, response} =
               Surveys.get_or_start_response(survey, student, %{course_id: course.id})

      assert response.cohort_id == nil
    end

    test "a response cannot be created without a course" do
      student = insert(:account)
      survey = published_survey()

      # Without a course there is no cohort to resolve, so every respondent
      # would be attributed to their account and named in the results - the
      # opposite of what a feedback survey promises. A caller that forgot the
      # course has a wiring bug, not a mode to support quietly.
      assert {:error, :no_course} = Surveys.get_or_start_response(survey, student, %{})

      assert {:error, :no_course} =
               Surveys.get_or_start_response(survey, student, %{course_id: nil})

      assert Repo.aggregate(SurveyResponse, :count) == 0
    end

    test "attribution is resolved server-side and cannot be supplied by the caller" do
      course = insert(:course)
      {student, cohort} = cohort_enrolled(course)
      survey = published_survey()
      attacker_cohort = insert(:cohort)

      {:ok, response} =
        Surveys.get_or_start_response(survey, student, %{
          course_id: course.id,
          cohort_id: attacker_cohort.id
        })

      assert response.cohort_id == cohort.id
    end

    test "attribution is decided once and a later save cannot rewrite it" do
      course = insert(:course)
      {student, cohort} = cohort_enrolled(course)
      survey = published_survey()
      {:ok, response} = Surveys.get_or_start_response(survey, student, %{course_id: course.id})

      {:ok, updated} =
        response
        |> SurveyResponse.progress_changeset(%{
          cohort_id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate()
        })
        |> Repo.update()

      assert updated.cohort_id == cohort.id
      assert updated.account_id == student.id
    end
  end

  describe "starting and resuming" do
    test "a survey that is not published cannot be answered" do
      student = insert(:account)

      for status <- [:draft, :closed, :archived] do
        survey = insert(:survey, status: status)
        assert {:error, :not_open} = start(survey, student)
      end
    end

    test "starting twice resumes the same response rather than creating a second" do
      student = insert(:account)
      survey = published_survey()

      {:ok, first} = start(survey, student)
      {:ok, second} = start(survey, student)

      assert first.id == second.id
      assert Repo.aggregate(SurveyResponse, :count) == 1
    end

    test "a finished survey reports completion instead of reopening" do
      student = insert(:account)
      survey = published_survey()

      {:ok, response} = start(survey, student)
      {:ok, _} = Surveys.complete_response(response)

      assert {:already_completed, completed} = start(survey, student)
      assert completed.id == response.id
    end

    test "the database refuses a second response even if the context is bypassed" do
      student = insert(:account)
      survey = published_survey()
      {:ok, _} = start(survey, student)

      assert {:error, changeset} =
               %SurveyResponse{}
               |> SurveyResponse.create_changeset(%{
                 survey_id: survey.id,
                 account_id: student.id
               })
               |> Repo.insert()

      refute changeset.valid?
    end

    test "two students answering the same survey are independent" do
      survey = published_survey()

      {:ok, a} = start(survey, insert(:account))
      {:ok, b} = start(survey, insert(:account))

      refute a.id == b.id
    end
  end

  describe "autosave" do
    setup do
      survey = published_survey()
      question = insert(:survey_question, survey: survey, type: :scale)
      {:ok, response} = start(survey, insert(:account))

      %{survey: survey, question: question, response: response}
    end

    test "changing an answer replaces the row instead of adding one", ctx do
      {:ok, _} = Surveys.save_answer(ctx.response, ctx.question, %{"number" => 2})
      {:ok, _} = Surveys.save_answer(ctx.response, ctx.question, %{"number" => 5})

      assert Repo.aggregate(SurveyAnswer, :count) == 1

      [answer] = Surveys.list_answers(ctx.response.id)
      assert answer.value_numeric == 5.0
    end

    test "a matrix saves one row at a time without clobbering the others", ctx do
      row_a = Ecto.UUID.generate()
      row_b = Ecto.UUID.generate()

      question =
        insert(:survey_question,
          survey: ctx.survey,
          type: :multi_scale,
          config: %{
            "rows" => [%{"id" => row_a, "text" => "Pace"}, %{"id" => row_b, "text" => "Depth"}],
            "min" => 1,
            "max" => 5,
            "step" => 1
          }
        )

      {:ok, _} = Surveys.save_answer(ctx.response, question, %{"row_id" => row_a, "number" => 2})
      {:ok, _} = Surveys.save_answer(ctx.response, question, %{"row_id" => row_b, "number" => 4})
      {:ok, _} = Surveys.save_answer(ctx.response, question, %{"row_id" => row_a, "number" => 3})

      answers = Surveys.answers_map(ctx.response.id)

      assert answers[{question.id, row_a}].value_numeric == 3.0
      assert answers[{question.id, row_b}].value_numeric == 4.0
      assert map_size(answers) == 2
    end

    test "an invalid answer is rejected and leaves the previous one standing", ctx do
      {:ok, _} = Surveys.save_answer(ctx.response, ctx.question, %{"number" => 4})

      assert {:error, changeset} =
               Surveys.save_answer(ctx.response, ctx.question, %{"number" => "four"})

      refute changeset.valid?

      [answer] = Surveys.list_answers(ctx.response.id)
      assert answer.value_numeric == 4.0
    end

    test "a skip is recorded as a row, distinguishable from never reaching the question", ctx do
      {:ok, answer} = Surveys.skip_answer(ctx.response, ctx.question)

      assert answer.skipped
      assert answer.value_numeric == nil
      assert Repo.aggregate(SurveyAnswer, :count) == 1
    end

    test "answering a question after skipping it replaces the skip", ctx do
      {:ok, _} = Surveys.skip_answer(ctx.response, ctx.question)
      {:ok, _} = Surveys.save_answer(ctx.response, ctx.question, %{"number" => 1})

      [answer] = Surveys.list_answers(ctx.response.id)
      refute answer.skipped
      assert answer.value_numeric == 1.0
    end
  end

  describe "partial responses stay visible" do
    test "an abandoned response keeps its answers and is still listed" do
      survey = published_survey()
      q1 = insert(:survey_question, survey: survey, position: 0)
      _q2 = insert(:survey_question, survey: survey, position: 1)
      {:ok, response} = start(survey, insert(:account))

      {:ok, _} = Surveys.save_answer(response, q1, %{"number" => 3})
      {:ok, _} = Surveys.abandon_response(response)

      assert [listed] = Surveys.list_responses(survey.id)
      assert listed.status == :abandoned
      assert [answer] = Surveys.list_answers(listed.id)
      assert answer.value_numeric == 3.0
    end

    test "an in-progress response is counted, not hidden" do
      survey = published_survey()
      {:ok, _} = start(survey, insert(:account))
      {:ok, done} = start(survey, insert(:account))
      {:ok, _} = Surveys.complete_response(done)

      counts = Surveys.count_responses_by_status(survey.id)

      assert counts == %{in_progress: 1, completed: 1, abandoned: 0}
    end
  end

  describe "lifecycle of one response" do
    test "completing stamps completed_at once and keeps the first value" do
      survey = published_survey()
      {:ok, response} = start(survey, insert(:account))

      {:ok, completed} = Surveys.complete_response(response)
      assert completed.completed_at

      {:ok, again} = Surveys.complete_response(completed)
      assert again.completed_at == completed.completed_at
    end

    test "advancing moves the resume point" do
      survey = published_survey()
      question = insert(:survey_question, survey: survey)
      {:ok, response} = start(survey, insert(:account))

      {:ok, advanced} = Surveys.advance_response(response, question.id)

      assert advanced.current_question_id == question.id
    end

    test "resetting a response lets the student answer again" do
      student = insert(:account)
      survey = published_survey()
      question = insert(:survey_question, survey: survey)

      {:ok, response} = start(survey, student)
      {:ok, _} = Surveys.save_answer(response, question, %{"number" => 1})
      {:ok, _} = Surveys.complete_response(response)

      {:ok, _} = Surveys.reset_response(Repo.reload!(response))

      # The answers go with it - that is why the function is named for deletion.
      assert Repo.aggregate(SurveyAnswer, :count) == 0
      assert {:ok, fresh} = start(survey, student)
      assert fresh.status == :in_progress
    end
  end

  describe "listing and filtering" do
    test "responses can be filtered by status and by cohort" do
      course = insert(:course)
      {student, cohort} = cohort_enrolled(course)
      survey = published_survey()

      {:ok, cohort_response} =
        Surveys.get_or_start_response(survey, student, %{course_id: course.id})

      {:ok, _solo} = start(survey, insert(:account))
      {:ok, _} = Surveys.complete_response(cohort_response)

      assert [found] = Surveys.list_responses(survey.id, cohort_id: cohort.id)
      assert found.id == cohort_response.id

      assert [completed] = Surveys.list_responses(survey.id, status: :completed)
      assert completed.id == cohort_response.id

      assert length(Surveys.list_responses(survey.id)) == 2
    end
  end

  describe "resolve_cohort/2" do
    test "returns nil without a course" do
      assert Responses.resolve_cohort(Ecto.UUID.generate(), nil) == nil
    end

    test "ignores a cohort whose enrollment is not active" do
      course = insert(:course)
      student = insert(:account)
      cohort = insert(:cohort)
      insert(:cohort_membership, cohort_id: cohort.id, account_id: student.id)
      insert(:enrollment, course_id: course.id, cohort_id: cohort.id, status: :dropped)

      assert Responses.resolve_cohort(student.id, course.id) == nil
    end
  end
end
