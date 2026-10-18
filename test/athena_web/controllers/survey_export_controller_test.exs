defmodule AthenaWeb.SurveyExportControllerTest do
  @moduledoc """
  The download itself: permissions, the CSV formatting conventions, and the
  spreadsheet-specific hazards of exporting text students typed.
  """
  use AthenaWeb.ConnCase, async: true

  import Athena.Factory

  alias Athena.Surveys

  defp sign_in(conn, permissions, policies \\ %{}) do
    user = insert(:account, role: insert(:role, permissions: permissions, policies: policies))
    {init_test_session(conn, %{"account_id" => user.id}), user}
  end

  setup %{conn: conn} do
    {conn, user} =
      sign_in(conn, ["surveys.read", "surveys.results.read", "surveys.results.export"])

    survey = insert(:survey, owner_id: user.id, status: :published, title: "Mid-course feedback")
    {:ok, question} = Surveys.add_question(survey, :open_text)

    %{conn: conn, user: user, survey: survey, question: question}
  end

  defp answer(survey, question, text, opts \\ []) do
    response =
      insert(:survey_response,
        survey: survey,
        account_id: insert(:account).id,
        cohort_id: Keyword.get(opts, :cohort_id),
        status: :completed
      )

    {:ok, _} = Surveys.save_answer(response, question, %{"text" => text})
    response
  end

  describe "permissions" do
    test "the export permission is required", ctx do
      {conn, _user} = sign_in(ctx.conn, ["surveys.read", "surveys.results.read"])

      conn = get(conn, ~p"/studio/surveys/#{ctx.survey.id}/export.csv")

      assert response(conn, 403)
    end

    test "own_only is enforced on the record, not just the screen", %{conn: conn} do
      stranger = insert(:survey, owner_id: Ecto.UUID.generate(), status: :published)

      {conn, _user} =
        sign_in(conn, ["surveys.read", "surveys.results.export"], %{
          "surveys.read" => ["own_only"]
        })

      # The link is on a screen they cannot reach, but a URL is a URL.
      conn = get(conn, ~p"/studio/surveys/#{stranger.id}/export.csv")

      assert response(conn, 403)
    end

    test "a missing survey is a 404, not a 403", ctx do
      conn = get(ctx.conn, ~p"/studio/surveys/#{Ecto.UUID.generate()}/export.csv")

      assert response(conn, 404)
    end
  end

  describe "the file" do
    test "is sent as a CSV attachment named after the survey", ctx do
      answer(ctx.survey, ctx.question, "It was good")

      conn = get(ctx.conn, ~p"/studio/surveys/#{ctx.survey.id}/export.csv")

      assert response_content_type(conn, :csv)

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "survey_Mid_course_feedback.csv"
    end

    test "starts with a UTF-8 BOM so Excel reads Cyrillic correctly", ctx do
      answer(ctx.survey, ctx.question, "Отличный курс")

      body = ctx.conn |> get(~p"/studio/surveys/#{ctx.survey.id}/export.csv") |> response(200)

      assert String.starts_with?(body, "﻿")
      assert body =~ "Отличный курс"
    end

    test "the long shape has its own filename and headers", ctx do
      answer(ctx.survey, ctx.question, "Fine")

      conn = get(ctx.conn, ~p"/studio/surveys/#{ctx.survey.id}/export.long.csv")
      body = response(conn, 200)

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "survey_Mid_course_feedback_long.csv"

      assert body =~ "response_id"
      assert body =~ "value_label"
    end

    test "rows are CRLF separated, as the CSV convention expects", ctx do
      answer(ctx.survey, ctx.question, "Fine")

      body = ctx.conn |> get(~p"/studio/surveys/#{ctx.survey.id}/export.csv") |> response(200)

      assert body =~ "\r\n"
    end

    test "follows the cohort filter, so the file matches what was on screen", ctx do
      a = insert(:cohort, name: "Group A")
      b = insert(:cohort, name: "Group B")

      answer(ctx.survey, ctx.question, "From A", cohort_id: a.id)
      answer(ctx.survey, ctx.question, "From B", cohort_id: b.id)

      body =
        ctx.conn
        |> get(~p"/studio/surveys/#{ctx.survey.id}/export.csv?#{%{"cohort_id" => a.id}}")
        |> response(200)

      assert body =~ "From A"
      refute body =~ "From B"
    end
  end

  describe "escaping" do
    test "quotes a value containing the separator, a quote or a newline", ctx do
      answer(ctx.survey, ctx.question, ~s(Good, but "rushed"\nespecially week 3))

      body = ctx.conn |> get(~p"/studio/surveys/#{ctx.survey.id}/export.csv") |> response(200)

      # Doubled quotes inside a quoted field, per RFC 4180.
      assert body =~ ~s("Good, but ""rushed"")
    end

    test "disarms a value a spreadsheet would run as a formula", ctx do
      answer(ctx.survey, ctx.question, "=1+1")

      body = ctx.conn |> get(~p"/studio/surveys/#{ctx.survey.id}/export.csv") |> response(200)

      # Survey answers are arbitrary text typed by students, so a leading =
      # is a live concern, not a theoretical one. The text stays intact.
      assert body =~ "'=1+1"
      refute body =~ ~r/(?<!')=1\+1/
    end

    test "disarms the other formula-leading characters too", ctx do
      for text <- ["+SUM(A1)", "-2+3", "@import"] do
        survey = insert(:survey, owner_id: ctx.user.id, status: :published)
        {:ok, question} = Surveys.add_question(survey, :open_text)
        answer(survey, question, text)

        body = ctx.conn |> get(~p"/studio/surveys/#{survey.id}/export.csv") |> response(200)

        assert body =~ "'" <> text, "did not disarm #{text}"
      end
    end

    test "booleans are written as words, not as Elixir terms", ctx do
      {:ok, question} = Surveys.add_question(ctx.survey, :scale)

      response =
        insert(:survey_response, survey: ctx.survey, account_id: insert(:account).id)

      {:ok, _} = Surveys.skip_answer(response, question)

      body =
        ctx.conn |> get(~p"/studio/surveys/#{ctx.survey.id}/export.long.csv") |> response(200)

      assert body =~ "true"
    end
  end

  describe "privacy" do
    test "a cohort respondent's name and id are absent from the file", ctx do
      cohort = insert(:cohort, name: "Group A")
      student = insert(:account, login: "quiet_student")
      insert(:profile, owner: student, first_name: "Anna", last_name: "Petrova")

      response =
        insert(:survey_response,
          survey: ctx.survey,
          account_id: student.id,
          cohort_id: cohort.id,
          status: :completed
        )

      {:ok, _} = Surveys.save_answer(response, ctx.question, %{"text" => "Loved the labs"})

      for path <- [
            ~p"/studio/surveys/#{ctx.survey.id}/export.csv",
            ~p"/studio/surveys/#{ctx.survey.id}/export.long.csv"
          ] do
        body = ctx.conn |> get(path) |> response(200)

        assert body =~ "Loved the labs"
        assert body =~ "Group A"
        refute body =~ student.id
        refute body =~ "quiet_student"
        refute body =~ "Anna"
        refute body =~ "Petrova"
      end
    end
  end
end
