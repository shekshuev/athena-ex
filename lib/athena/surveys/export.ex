defmodule Athena.Surveys.Export do
  @moduledoc """
  The two table shapes a survey's answers are exported in.

  Data only - headers and rows, no CSV escaping, no HTTP. The controller does
  the formatting, which is what lets the shape of an export be asserted
  without parsing a download.

  ## Why two shapes

  `wide/2` is one row per respondent and one column per question, which is
  what a spreadsheet wants and what someone eyeballing the answers expects.

  `long/2` is one row per answer - `response_id`, question, row, value - which
  is what SPSS and R actually want: every analysis in those tools starts by
  reshaping a wide table into this, and a matrix question has no honest wide
  representation at all beyond one column per row.

  ## Privacy

  The respondent column comes from `Athena.Surveys.Results.respondent_labels/1`,
  the same function the screen uses, so a cohort respondent is a cohort and an
  opaque number here too. No `account_id` is ever written.

  Timestamps are truncated to the **day**. The exact second is never
  analytically useful for a survey, and a precise timestamp in a file is the
  one thing that could be matched against a lecture schedule, a progress row
  or someone's memory of who left the room early - which would undo the
  labelling above without anybody noticing.
  """

  import Ecto.Query

  alias Athena.Repo

  alias Athena.Surveys.{
    Prompt,
    QuestionTypes,
    Results,
    SurveyAnswer,
    SurveyQuestion,
    SurveyResponse
  }

  @doc """
  One row per respondent, one column per question - and for a matrix, one
  column per row of it, since a matrix is a battery of separate items.
  """
  @spec wide(binary(), keyword()) :: %{headers: [String.t()], rows: [[term()]]}
  def wide(survey_id, opts \\ []) do
    questions = ordered_questions(survey_id)
    responses = scoped_responses(survey_id, opts)
    labels = Results.respondent_labels(responses)
    answers = answers_by_response(survey_id, opts)
    columns = wide_columns(questions)

    headers =
      ["respondent", "cohort", "status", "started_on", "completed_on"] ++
        Enum.map(columns, & &1.header)

    rows =
      responses
      |> Enum.sort_by(&label_text(labels, &1.id))
      |> Enum.map(fn response ->
        per_response = Map.get(answers, response.id, %{})

        [
          label_text(labels, response.id),
          cohort_text(labels, response.id),
          response.status,
          to_day(response.started_at),
          to_day(response.completed_at)
        ] ++
          Enum.map(columns, fn column ->
            cell(column, Map.get(per_response, {column.question.id, column.row_key}))
          end)
      end)

    %{headers: headers, rows: rows}
  end

  @doc """
  One row per answer: the tidy shape, with both the raw code and its label.

  Both, because a code is what you recode and filter on and a label is what
  makes a table readable - and because the ids in `value_code` are the same
  ids the branching rules use, so a reader can follow a path through the
  survey in the data.
  """
  @spec long(binary(), keyword()) :: %{headers: [String.t()], rows: [[term()]]}
  def long(survey_id, opts \\ []) do
    questions = ordered_questions(survey_id)
    by_id = Map.new(questions, &{&1.id, &1})
    responses = scoped_responses(survey_id, opts)
    labels = Results.respondent_labels(responses)
    statuses = Map.new(responses, &{&1.id, &1})

    headers = ~w(response_id respondent cohort status completed_on question_position question_id
                 question_type question_text row_key row_label value_code value_label
                 value_numeric value_text skipped)

    rows =
      survey_id
      |> all_answers(opts)
      |> Enum.flat_map(fn answer ->
        case Map.get(by_id, answer.question_id) do
          nil -> []
          question -> [long_row(answer, question, labels, statuses)]
        end
      end)
      |> Enum.sort_by(fn row -> {Enum.at(row, 1), Enum.at(row, 5), Enum.at(row, 9)} end)

    %{headers: headers, rows: rows}
  end

  defp long_row(answer, question, labels, statuses) do
    response = Map.get(statuses, answer.response_id)

    [
      # A random UUID carrying no account information, kept because R and SPSS
      # need a reliable key to group a respondent's rows by - two students can
      # share a name, so the label alone will not do.
      answer.response_id,
      label_text(labels, answer.response_id),
      cohort_text(labels, answer.response_id),
      response && response.status,
      response && to_day(response.completed_at),
      question.position + 1,
      question.id,
      question.type,
      Prompt.to_text(question.body),
      answer.row_key,
      row_label(question, answer.row_key),
      value_code(answer),
      answer_label(question, answer),
      answer.value_numeric,
      answer.value_text,
      answer.skipped
    ]
  end

  # -- columns --------------------------------------------------------------

  defp wide_columns(questions) do
    Enum.flat_map(questions, fn question ->
      prompt = Prompt.to_text(question.body)
      number = question.position + 1

      case question.type do
        :multi_scale ->
          question
          |> rows()
          |> Enum.map(fn row ->
            %{
              question: question,
              row_key: row["id"],
              header: "Q#{number}.#{row["text"]}"
            }
          end)

        _ ->
          [%{question: question, row_key: "", header: "Q#{number}. #{prompt}"}]
      end
    end)
  end

  defp cell(_column, nil), do: nil
  defp cell(_column, %SurveyAnswer{skipped: true}), do: "(declined)"
  defp cell(column, answer), do: answer_label(column.question, answer)

  # -- value rendering ------------------------------------------------------

  @doc """
  A single readable string for one answer: the chosen labels, the number, or
  the text.

  Distinct from the screen's renderer, which draws per-type markup - a list
  for a ranking, a definition list for a matrix. A cell has to be one string,
  so a ranking becomes an ordered, separated list and a matching becomes
  arrow pairs.
  """
  @spec answer_label(SurveyQuestion.t(), SurveyAnswer.t()) :: String.t() | nil
  def answer_label(_question, %SurveyAnswer{skipped: true}), do: "(declined)"

  def answer_label(%{type: :open_text}, answer), do: answer.value_text

  def answer_label(%{type: :matching} = question, answer) do
    right_labels = question |> pairs() |> Map.new(&{&1["id"], &1["right"]})

    question
    |> pairs()
    |> Enum.map_join("; ", fn pair ->
      case get_in(answer.value, ["pairs", pair["id"]]) do
        nil -> "#{pair["left"]} -> "
        right_id -> "#{pair["left"]} -> #{Map.get(right_labels, right_id, right_id)}"
      end
    end)
  end

  def answer_label(%{type: :ranking} = question, answer) do
    labels = question |> items() |> Map.new(&{&1["id"], &1["text"]})

    answer.value_choice_ids
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.map_join("; ", fn {id, rank} -> "#{rank}. #{Map.get(labels, id, id)}" end)
  end

  def answer_label(question, answer) do
    cond do
      is_number(answer.value_numeric) and QuestionTypes.quantitative?(question.type) ->
        format_number(answer.value_numeric)

      answer.value_choice_ids not in [nil, []] ->
        labels = choice_labels(question)

        answer.value_choice_ids
        |> Enum.map_join("; ", fn id ->
          cond do
            id == QuestionTypes.other_choice_id() ->
              "Other: #{answer.value_text}"

            true ->
              Map.get(labels, id, id)
          end
        end)

      is_number(answer.value_numeric) ->
        format_number(answer.value_numeric)

      true ->
        answer.value_text
    end
  end

  # The stored code rather than its label: ids are what a reader recodes and
  # filters on, and they are the same ids the branching rules reference.
  defp value_code(%SurveyAnswer{skipped: true}), do: nil

  defp value_code(answer) do
    case List.wrap(answer.value_choice_ids) do
      [] -> answer.value_numeric && format_number(answer.value_numeric)
      ids -> Enum.join(ids, ";")
    end
  end

  # -- loading --------------------------------------------------------------

  defp ordered_questions(survey_id) do
    SurveyQuestion
    |> where([q], q.survey_id == ^survey_id)
    |> order_by([q], asc: q.position)
    |> Repo.all()
  end

  defp scoped_responses(survey_id, opts) do
    SurveyResponse
    |> where([r], r.survey_id == ^survey_id)
    |> filter_cohort(opts)
    |> Repo.all()
  end

  defp filter_cohort(query, opts) do
    case Keyword.get(opts, :cohort_id) do
      nil -> query
      cohort_id -> where(query, [r], r.cohort_id == ^cohort_id)
    end
  end

  defp all_answers(survey_id, opts) do
    SurveyAnswer
    |> join(:inner, [a], q in SurveyQuestion, on: q.id == a.question_id)
    |> join(:inner, [a, _q], r in SurveyResponse, on: r.id == a.response_id)
    |> where([_a, q, _r], q.survey_id == ^survey_id)
    |> then(fn query ->
      case Keyword.get(opts, :cohort_id) do
        nil -> query
        cohort_id -> where(query, [_a, _q, r], r.cohort_id == ^cohort_id)
      end
    end)
    |> select([a, _q, _r], a)
    |> Repo.all()
  end

  defp answers_by_response(survey_id, opts) do
    survey_id
    |> all_answers(opts)
    |> Enum.group_by(& &1.response_id)
    |> Map.new(fn {response_id, answers} ->
      {response_id, Map.new(answers, &{{&1.question_id, &1.row_key}, &1})}
    end)
  end

  # -- labels ---------------------------------------------------------------

  defp label_text(labels, response_id) do
    case Map.get(labels, response_id) do
      nil -> nil
      label -> label.text
    end
  end

  defp cohort_text(labels, response_id) do
    case Map.get(labels, response_id) do
      %{kind: :cohort, cohort_name: name} -> name
      _ -> nil
    end
  end

  defp to_day(nil), do: nil
  defp to_day(%DateTime{} = datetime), do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  defp rows(question), do: List.wrap(question.config["rows"])
  defp pairs(question), do: List.wrap(question.config["pairs"])
  defp items(question), do: List.wrap(question.config["items"])

  defp row_label(%{type: :multi_scale} = question, row_key) do
    case Enum.find(rows(question), &(&1["id"] == row_key)) do
      nil -> nil
      row -> row["text"]
    end
  end

  defp row_label(_question, _row_key), do: nil

  defp choice_labels(%{type: :dichotomous} = question) do
    %{
      QuestionTypes.yes_choice_id() => question.config["yes_label"],
      QuestionTypes.no_choice_id() => question.config["no_label"]
    }
  end

  defp choice_labels(question) do
    question.config["options"] |> List.wrap() |> Map.new(&{&1["id"], &1["text"]})
  end

  defp format_number(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(value, decimals: 4)
  end

  defp format_number(value), do: to_string(value)
end
