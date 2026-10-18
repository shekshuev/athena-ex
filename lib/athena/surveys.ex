defmodule Athena.Surveys do
  @moduledoc """
  Surveys: standalone questionnaires for collecting feedback from students.

  A survey is authored once in its own builder, lives outside the content
  library, and is referenced from a course by a `:survey` block - where it
  renders in place, like any other block, rather than taking over the screen
  the way `:quiz_exam` and `:ticket_exam` do. It is not graded, earns no XP,
  and collects no engagement telemetry.

  ## Shape of the context

    * `Athena.Surveys.Surveys` - the survey record and its lifecycle
    * `Athena.Surveys.Questions` - questions, ordering, type changes
    * `Athena.Surveys.Branches` - branching rules
    * `Athena.Surveys.Responses` - taking a survey: start, autosave, finish
    * `Athena.Surveys.QuestionTypes` - the type registry and per-type configs

  ## Privacy

  A response always carries `account_id`. What makes a survey feel safe to
  answer honestly is enforced one layer up: when a student reached the survey
  through a cohort, `cohort_id` is set and the results UI and exports show
  only the cohort and its aggregates, never who said what. When they are
  enrolled individually there is no group to hide in, and the response is
  shown against the student.

  This is privacy at the presentation layer, deliberately - not anonymity.
  Anyone with database access can see who answered. In exchange, resuming an
  interrupted survey, enforcing one response per student and showing partial
  responses all fall out of a single unique index instead of needing tokens
  and a separate ledger. See `Athena.Surveys.SurveyResponse`.
  """

  alias Athena.Surveys.{Branches, Flow, Questions, Responses, Surveys}

  @doc """
  Loads a survey's questions and rules into an `Athena.Surveys.Flow` - the
  pure branching engine.

  This is the only place the flow touches the database; `Flow` itself is
  pure, which is what lets the builder's preview walk a branch in socket
  assigns while the player runs the identical logic against real rows.
  """
  @spec load_flow(Athena.Surveys.Survey.t() | binary()) :: Flow.t() | nil
  def load_flow(%Athena.Surveys.Survey{} = survey) do
    Flow.build(survey, Questions.list_questions(survey.id), Branches.list_branches(survey.id))
  end

  def load_flow(survey_id) when is_binary(survey_id) do
    case Surveys.get_survey(survey_id) do
      nil -> nil
      survey -> load_flow(survey)
    end
  end

  # Surveys
  defdelegate list_surveys_for_user(user, params \\ %{}, opts \\ []),
    to: Surveys,
    as: :list_for_user

  defdelegate get_survey(id), to: Surveys
  defdelegate get_survey_with_questions(id), to: Surveys
  defdelegate create_survey(user, attrs), to: Surveys
  defdelegate update_survey(survey, attrs), to: Surveys
  defdelegate change_survey(survey, attrs \\ %{}), to: Surveys
  defdelegate publish_survey(survey), to: Surveys, as: :publish
  defdelegate close_survey(survey), to: Surveys, as: :close
  defdelegate reopen_survey(survey), to: Surveys, as: :reopen
  defdelegate archive_survey(survey), to: Surveys, as: :archive
  defdelegate delete_survey(survey), to: Surveys
  defdelegate duplicate_as_version(survey, user), to: Surveys
  defdelegate survey_editable?(survey), to: Surveys, as: :editable?
  defdelegate survey_has_responses?(survey), to: Surveys, as: :has_responses?
  defdelegate question_count(survey), to: Surveys
  defdelegate can_manage_survey?(user, survey), to: Surveys, as: :can_manage?

  # Questions
  defdelegate list_questions(survey_id), to: Questions
  defdelegate get_question(id), to: Questions
  defdelegate add_question(survey, type, attrs \\ %{}), to: Questions
  defdelegate update_question(question, attrs), to: Questions
  defdelegate change_question(question, attrs \\ %{}), to: Questions
  defdelegate change_question_type(question, type), to: Questions
  defdelegate delete_question(question), to: Questions
  defdelegate duplicate_question(question), to: Questions
  defdelegate reorder_questions(survey_id, ordered_ids), to: Questions

  # Branches
  defdelegate list_branches(survey_id), to: Branches
  defdelegate list_branches_for_question(question_id), to: Branches, as: :list_for_question
  defdelegate branches_by_question(survey_id), to: Branches
  defdelegate get_branch(id), to: Branches
  defdelegate add_branch(survey, question, attrs), to: Branches
  defdelegate update_branch(branch, attrs), to: Branches
  defdelegate change_branch(branch, attrs \\ %{}), to: Branches
  defdelegate delete_branch(branch), to: Branches
  defdelegate reorder_branches(question_id, ordered_ids), to: Branches
  defdelegate any_branches?(survey), to: Branches

  # Flow
  defdelegate first_question(flow), to: Flow
  defdelegate next_question(flow, current, answers), to: Flow
  defdelegate next_page(flow, page, answers), to: Flow
  defdelegate previous_question(flow, history), to: Flow, as: :previous
  defdelegate visible_questions(flow, answers \\ %{}), to: Flow
  defdelegate questions_on_page(flow, page), to: Flow
  defdelegate validate_graph(flow), to: Flow

  # Responses
  defdelegate get_response(survey_id, account_id), to: Responses

  defdelegate get_or_start_response(survey, user, context \\ %{}),
    to: Responses,
    as: :get_or_start

  defdelegate save_answer(response, question, value, opts \\ []), to: Responses
  defdelegate skip_answer(response, question, value \\ %{}), to: Responses
  defdelegate list_answers(response_id), to: Responses
  defdelegate answers_map(response_id), to: Responses
  defdelegate advance_response(response, question_id), to: Responses, as: :advance
  defdelegate complete_response(response), to: Responses, as: :complete
  defdelegate abandon_response(response), to: Responses, as: :abandon
  defdelegate reset_response(response), to: Responses
  defdelegate list_responses(survey_id, opts \\ []), to: Responses
  defdelegate count_responses_by_status(survey_id), to: Responses, as: :count_by_status
end
