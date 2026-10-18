defmodule Athena.Surveys.ExportTest do
  @moduledoc """
  The shape of the two export tables. Asserted as data, which is why the
  module returns headers and rows rather than a CSV string.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys
  alias Athena.Surveys.Export

  defp add(survey, type, attrs \\ %{}) do
    {:ok, question} = Surveys.add_question(survey, type, attrs)
    question
  end

  defp respond(survey, answers, opts \\ []) do
    response =
      insert(:survey_response,
        survey: survey,
        account_id: Keyword.get_lazy(opts, :account_id, fn -> insert(:account).id end),
        cohort_id: Keyword.get(opts, :cohort_id),
        status: Keyword.get(opts, :status, :completed),
        completed_at: Keyword.get(opts, :completed_at)
      )

    for {question, value} <- answers do
      case value do
        :skip -> Surveys.skip_answer(response, question)
        _ -> Surveys.save_answer(response, question, value)
      end
    end

    response
  end

  defp column(%{headers: headers, rows: rows}, name) do
    index = Enum.find_index(headers, &(&1 == name))
    Enum.map(rows, &Enum.at(&1, index))
  end

  describe "wide/2" do
    setup do
      survey = insert(:survey, status: :published)
      {config, [fast, slow]} = choice_config(["Too fast", "Too slow"])

      pace =
        insert(:survey_question,
          survey: survey,
          type: :single_choice,
          config: config,
          position: 0,
          body: tiptap_doc("How was the pace?")
        )

      note =
        add(survey, :open_text, %{"position" => 1, "body" => tiptap_doc("Anything else?")})

      %{survey: survey, pace: pace, note: note, fast: fast, slow: slow}
    end

    test "one row per respondent and one column per question", ctx do
      cohort = insert(:cohort, name: "Group A")

      respond(
        ctx.survey,
        [{ctx.pace, %{"choice_id" => ctx.fast}}, {ctx.note, %{"text" => "More labs"}}],
        cohort_id: cohort.id
      )

      respond(ctx.survey, [{ctx.pace, %{"choice_id" => ctx.slow}}], cohort_id: cohort.id)

      table = Export.wide(ctx.survey.id)

      assert Enum.take(table.headers, 5) ==
               ~w(respondent cohort status started_on completed_on)

      assert Enum.at(table.headers, 5) == "Q1. How was the pace?"
      assert Enum.at(table.headers, 6) == "Q2. Anything else?"
      assert length(table.rows) == 2

      # Labels, not ids: a spreadsheet of UUIDs is unreadable.
      assert "Too fast" in column(table, "Q1. How was the pace?")
      assert "More labs" in column(table, "Q2. Anything else?")
    end

    test "a declined answer reads as declined, a never-reached one as blank", ctx do
      respond(ctx.survey, [{ctx.pace, %{"choice_id" => ctx.fast}}, {ctx.note, :skip}])

      table = Export.wide(ctx.survey.id)

      # The distinction the whole feature is careful about, carried into the
      # file: refusing is not the same as not getting there.
      assert column(table, "Q2. Anything else?") == ["(declined)"]

      respond(ctx.survey, [{ctx.pace, %{"choice_id" => ctx.slow}}])
      table = Export.wide(ctx.survey.id)

      assert nil in column(table, "Q2. Anything else?")
    end

    test "a matrix gets one column per row of it", ctx do
      row_a = Ecto.UUID.generate()
      row_b = Ecto.UUID.generate()

      matrix =
        insert(:survey_question,
          survey: ctx.survey,
          type: :multi_scale,
          position: 2,
          config: %{
            "rows" => [%{"id" => row_a, "text" => "Clear"}, %{"id" => row_b, "text" => "Useful"}],
            "min" => 1,
            "max" => 5,
            "step" => 1
          }
        )

      respond(ctx.survey, [
        {matrix, %{"row_id" => row_a, "number" => 4}},
        {matrix, %{"row_id" => row_b, "number" => 2}}
      ])

      table = Export.wide(ctx.survey.id)

      # A matrix is a battery of separate items; one column for the whole
      # thing would have nothing to put in it.
      assert "Q3.Clear" in table.headers
      assert "Q3.Useful" in table.headers
      assert column(table, "Q3.Clear") == ["4"]
      assert column(table, "Q3.Useful") == ["2"]
    end

    test "a ranking becomes an ordered list in one cell", ctx do
      ranking = add(ctx.survey, :ranking, %{"position" => 3})
      [first, second] = Enum.map(ranking.config["items"], & &1["id"])

      respond(ctx.survey, [{ranking, %{"choice_ids" => [second, first]}}])

      table = Export.wide(ctx.survey.id)
      [cell] = column(table, Enum.find(table.headers, &String.starts_with?(&1, "Q4")))

      assert cell =~ "1. Option 2"
      assert cell =~ "2. Option 1"
    end

    test "a matching answer becomes arrow pairs in one cell", ctx do
      matching = add(ctx.survey, :matching, %{"position" => 4})
      [p1, p2] = matching.config["pairs"]

      respond(ctx.survey, [
        {matching, %{"pairs" => %{p1["id"] => p2["id"]}}}
      ])

      table = Export.wide(ctx.survey.id)
      [cell] = column(table, Enum.find(table.headers, &String.starts_with?(&1, "Q5")))

      assert cell =~ "#{p1["left"]} -> #{p2["right"]}"
    end

    test "a write-in answer carries the text that was written", ctx do
      {config, _ids} = choice_config(["Labs", "Lectures"])

      question =
        insert(:survey_question,
          survey: ctx.survey,
          type: :single_choice,
          position: 5,
          config: Map.put(config, "other_allowed", true),
          body: tiptap_doc("Best part?")
        )

      respond(ctx.survey, [
        {question, %{"choice_id" => "other", "other_text" => "the field trip"}}
      ])

      table = Export.wide(ctx.survey.id)

      assert ["Other: the field trip"] == column(table, "Q6. Best part?")
    end

    test "can be narrowed to one cohort", ctx do
      a = insert(:cohort, name: "Group A")
      b = insert(:cohort, name: "Group B")

      respond(ctx.survey, [{ctx.pace, %{"choice_id" => ctx.fast}}], cohort_id: a.id)
      respond(ctx.survey, [{ctx.pace, %{"choice_id" => ctx.slow}}], cohort_id: b.id)

      table = Export.wide(ctx.survey.id, cohort_id: a.id)

      assert length(table.rows) == 1
      assert column(table, "cohort") == ["Group A"]
    end

    test "an empty survey still exports its headers", ctx do
      table = Export.wide(ctx.survey.id)

      assert table.rows == []
      assert "Q1. How was the pace?" in table.headers
    end
  end

  describe "long/2" do
    setup do
      survey = insert(:survey, status: :published)
      {config, [yes, no]} = choice_config(["Yes", "No"])

      choice =
        insert(:survey_question,
          survey: survey,
          type: :single_choice,
          config: config,
          position: 0,
          body: tiptap_doc("Would you recommend it?")
        )

      scale = add(survey, :scale, %{"position" => 1, "body" => tiptap_doc("Rate the pace")})

      %{survey: survey, choice: choice, scale: scale, yes: yes, no: no}
    end

    test "one row per answer, with both the code and its label", ctx do
      cohort = insert(:cohort, name: "Group A")

      respond(
        ctx.survey,
        [{ctx.choice, %{"choice_id" => ctx.yes}}, {ctx.scale, %{"number" => 4}}],
        cohort_id: cohort.id
      )

      table = Export.long(ctx.survey.id)

      assert length(table.rows) == 2

      # The code is the same id the branching rules use, so a reader can
      # follow a path through the survey in the data; the label is what makes
      # a table readable.
      assert ctx.yes in column(table, "value_code")
      assert "Yes" in column(table, "value_label")
      assert 4.0 in column(table, "value_numeric")
      assert column(table, "cohort") |> Enum.uniq() == ["Group A"]
    end

    test "carries the question's position, type and text" do
      survey = insert(:survey, status: :published)
      question = add(survey, :scale, %{"body" => tiptap_doc("How clear was it?")})

      respond(survey, [{question, %{"number" => 5}}])

      table = Export.long(survey.id)

      assert column(table, "question_position") == [1]
      assert column(table, "question_type") == [:scale]
      assert column(table, "question_text") == ["How clear was it?"]
    end

    test "a matrix row is its own row, labelled" do
      survey = insert(:survey, status: :published)
      row_a = Ecto.UUID.generate()
      row_b = Ecto.UUID.generate()

      matrix =
        insert(:survey_question,
          survey: survey,
          type: :multi_scale,
          config: %{
            "rows" => [%{"id" => row_a, "text" => "Clear"}, %{"id" => row_b, "text" => "Useful"}],
            "min" => 1,
            "max" => 5,
            "step" => 1
          }
        )

      respond(survey, [
        {matrix, %{"row_id" => row_a, "number" => 4}},
        {matrix, %{"row_id" => row_b, "number" => 2}}
      ])

      table = Export.long(survey.id)

      assert length(table.rows) == 2
      assert Enum.sort(column(table, "row_label")) == ["Clear", "Useful"]
      assert Enum.sort(column(table, "row_key")) == Enum.sort([row_a, row_b])
    end

    test "a declined answer is a row with skipped set, not a missing row", ctx do
      respond(ctx.survey, [{ctx.choice, :skip}])

      table = Export.long(ctx.survey.id)

      assert column(table, "skipped") == [true]
      assert column(table, "value_code") == [nil]
      assert column(table, "value_label") == ["(declined)"]
    end

    test "a response_id groups a respondent's rows reliably", ctx do
      respond(ctx.survey, [{ctx.choice, %{"choice_id" => ctx.yes}}, {ctx.scale, %{"number" => 4}}])

      table = Export.long(ctx.survey.id)

      # Two students can share a name, so the label alone will not do as a
      # grouping key for R or SPSS.
      assert table |> column("response_id") |> Enum.uniq() |> length() == 1
    end
  end

  describe "privacy" do
    test "no account id is ever written, in either shape" do
      survey = insert(:survey, status: :published)
      question = add(survey, :open_text)
      cohort = insert(:cohort, name: "Group A")

      student = insert(:account, login: "quiet_student")
      insert(:profile, owner: student, first_name: "Anna", last_name: "Petrova")

      respond(survey, [{question, %{"text" => "It was good"}}],
        cohort_id: cohort.id,
        account_id: student.id
      )

      for table <- [Export.wide(survey.id), Export.long(survey.id)] do
        flat = table.rows |> List.flatten() |> Enum.map(&to_string/1) |> Enum.join(" ")

        refute flat =~ student.id
        refute flat =~ "quiet_student"
        refute flat =~ "Anna"
        refute flat =~ "Petrova"
        assert flat =~ "Group A"
      end
    end

    test "an individually enrolled respondent is named, having no group to hide in" do
      survey = insert(:survey, status: :published)
      question = add(survey, :open_text)

      student = insert(:account)
      insert(:profile, owner: student, first_name: "Boris", last_name: "Ivanov")

      respond(survey, [{question, %{"text" => "Fine"}}], cohort_id: nil, account_id: student.id)

      table = Export.wide(survey.id)

      assert column(table, "respondent") == ["Boris Ivanov"]
      assert column(table, "cohort") == [nil]
    end

    test "timestamps are days, never instants" do
      survey = insert(:survey, status: :published)
      question = add(survey, :scale)
      completed = ~U[2026-03-14 15:09:26Z]

      respond(survey, [{question, %{"number" => 3}}], completed_at: completed)

      table = Export.wide(survey.id)

      # The exact second is never analytically useful, and is the one thing
      # that could be matched against a schedule or a progress row to
      # identify somebody.
      assert column(table, "completed_on") == ["2026-03-14"]
      refute table.rows |> List.flatten() |> Enum.any?(&match?(%DateTime{}, &1))
    end
  end
end
