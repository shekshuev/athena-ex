defmodule AthenaWeb.StudioLive.SurveyResultsTest do
  @moduledoc """
  The results screen.

  The identity tests are the point of the privacy promise this feature makes,
  so they assert over the rendered markup - including attributes, not only
  visible text - that a cohort respondent's name and account id appear
  nowhere.
  """
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Surveys

  defp sign_in(conn, permissions) do
    user = insert(:account, role: insert(:role, permissions: permissions))
    {init_test_session(conn, %{"account_id" => user.id}), user}
  end

  setup %{conn: conn} do
    {conn, user} = sign_in(conn, ["surveys.read"])
    survey = insert(:survey, owner_id: user.id, status: :published)

    %{conn: conn, user: user, survey: survey}
  end

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
        status: Keyword.get(opts, :status, :completed)
      )

    for {question, value} <- answers do
      case value do
        :skip -> Surveys.skip_answer(response, question)
        _ -> Surveys.save_answer(response, question, value)
      end
    end

    response
  end

  defp results(conn, survey, params \\ %{}) do
    query = if params == %{}, do: "", else: "?" <> URI.encode_query(params)
    live(conn, ~p"/studio/surveys/#{survey.id}/results" <> query)
  end

  describe "access" do
    test "needs surveys.read", %{conn: conn, user: user} do
      survey = insert(:survey, owner_id: user.id)
      {plain_conn, _user} = sign_in(conn, [])

      assert {:error, {:redirect, %{to: "/dashboard"}}} = results(plain_conn, survey)
    end

    test "own_only keeps a reader out of someone else's results", %{conn: conn} do
      stranger = insert(:survey, owner_id: Ecto.UUID.generate())

      # The screen gate passes, but the record-level policy does not.
      role =
        insert(:role,
          permissions: ["surveys.read"],
          policies: %{"surveys.read" => ["own_only"]}
        )

      intruder = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => intruder.id})

      assert {:error, {:live_redirect, %{to: "/studio/surveys", flash: flash}}} =
               results(conn, stranger)

      assert flash["error"] =~ "cannot read"
    end

    test "a missing survey redirects", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/studio/surveys"}}} =
               live(conn, ~p"/studio/surveys/#{Ecto.UUID.generate()}/results")
    end
  end

  describe "with no responses" do
    test "says so, and says partial answers will appear as they come", ctx do
      add(ctx.survey, :scale)

      {:ok, lv, _html} = results(ctx.conn, ctx.survey)

      assert has_element?(lv, "#no-responses")
      assert render(lv) =~ "do not have to wait"
    end
  end

  describe "overview" do
    setup ctx do
      q1 = add(ctx.survey, :scale, %{"position" => 0})
      q2 = add(ctx.survey, :open_text, %{"position" => 1})

      respond(ctx.survey, [{q1, %{"number" => 4}}, {q2, %{"text" => "Good"}}])
      respond(ctx.survey, [{q1, %{"number" => 2}}])
      respond(ctx.survey, [{q1, %{"number" => 5}}, {q2, :skip}])
      respond(ctx.survey, [], status: :abandoned)

      %{q1: q1, q2: q2}
    end

    test "shows the headline counts", ctx do
      {:ok, _lv, html} = results(ctx.conn, ctx.survey)

      assert html =~ "Started"
      assert html =~ "Finished"
      assert html =~ ">4<"
    end

    test "the funnel tells answered from declined from never reached", ctx do
      {:ok, _lv, html} = results(ctx.conn, ctx.survey)

      assert html =~ "Where people stopped"
      assert html =~ "Never reached"
      assert html =~ "Declined"
    end

    test "the funnel chart is a server-built config on the existing hook", ctx do
      {:ok, lv, _html} = results(ctx.conn, ctx.survey)

      canvas = lv |> element("#funnel-chart") |> render()

      # No new JavaScript: a survey chart is still a Chart.js config built on
      # the server and read by the engagement hook.
      assert canvas =~ ~s(phx-hook="EngagementChart")
      assert canvas =~ "data-config"
      assert canvas =~ "Answered"
    end
  end

  describe "questions tab" do
    setup ctx do
      {config, [fast, slow]} = choice_config(["Too fast", "Too slow"])

      choice =
        insert(:survey_question,
          survey: ctx.survey,
          type: :single_choice,
          config: config,
          position: 0
        )

      scale = add(ctx.survey, :scale, %{"position" => 1})

      for {c, n} <- [{fast, 5}, {fast, 4}, {slow, 2}, {slow, 1}] do
        respond(ctx.survey, [{choice, %{"choice_id" => c}}, {scale, %{"number" => n}}])
      end

      %{choice: choice, scale: scale, fast: fast, slow: slow}
    end

    test "shows a frequency table in the author's option order", ctx do
      {:ok, lv, _html} =
        results(ctx.conn, ctx.survey, %{"tab" => "questions", "question_id" => ctx.choice.id})

      html = render(lv)

      assert html =~ "Too fast"
      assert html =~ "Of those who answered"
      assert html =~ ~r/Too fast.*Too slow/s
      assert has_element?(lv, "#frequency-chart")
    end

    test "shows descriptives for a scale and not for a choice question", ctx do
      {:ok, scale_lv, _html} =
        results(ctx.conn, ctx.survey, %{"tab" => "questions", "question_id" => ctx.scale.id})

      scale_html = render(scale_lv)
      assert scale_html =~ "Median"
      assert scale_html =~ "Skewness"

      {:ok, choice_lv, _html} =
        results(ctx.conn, ctx.survey, %{"tab" => "questions", "question_id" => ctx.choice.id})

      # Averaging option ids would be a number with no meaning, so the panel
      # is simply absent.
      refute render(choice_lv) =~ "Skewness"
    end

    test "cross-tabulates two questions on request", ctx do
      {:ok, lv, _html} =
        results(ctx.conn, ctx.survey, %{"tab" => "questions", "question_id" => ctx.choice.id})

      html =
        lv
        |> form("form[phx-change=crosstab_with]", %{"question_id" => ctx.scale.id})
        |> render_change()

      assert html =~ "Chi-square test"
      assert html =~ "Total"
    end

    test "does not offer a multi-select to cross-tabulate against", ctx do
      {config, _ids} = choice_config(["A", "B"])
      multi = insert(:survey_question, survey: ctx.survey, type: :multiple_choice, config: config)

      {:ok, lv, _html} =
        results(ctx.conn, ctx.survey, %{"tab" => "questions", "question_id" => ctx.choice.id})

      options = lv |> element("#crosstab-select") |> render()

      # A multi-select respondent belongs in several rows at once, which is
      # not a contingency table - so it is left out rather than offered and
      # then refused.
      refute options =~ multi.id
      assert options =~ ctx.scale.id
    end

    test "a stale or forged question id is handled rather than crashing", ctx do
      {:ok, lv, _html} =
        results(ctx.conn, ctx.survey, %{"tab" => "questions", "question_id" => ctx.choice.id})

      # The dropdown filters candidates, but the event arrives over a socket
      # and a client is a client.
      html = render_change(lv, "crosstab_with", %{"question_id" => Ecto.UUID.generate()})

      assert html =~ "Cross-tabulate"
      refute html =~ "Chi-square test"
    end

    test "shows reliability for a matrix", ctx do
      row_ids = Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)

      matrix =
        insert(:survey_question,
          survey: ctx.survey,
          type: :multi_scale,
          position: 2,
          config: %{
            "rows" =>
              Enum.zip(row_ids, ["Clear", "Useful", "Paced"])
              |> Enum.map(fn {id, text} -> %{"id" => id, "text" => text} end),
            "min" => 1,
            "max" => 5,
            "step" => 1
          }
        )

      for {a, b, c} <- [{4, 4, 5}, {5, 4, 5}, {2, 2, 1}, {3, 3, 2}, {5, 5, 4}] do
        respond(ctx.survey, [
          {matrix, %{"row_id" => Enum.at(row_ids, 0), "number" => a}},
          {matrix, %{"row_id" => Enum.at(row_ids, 1), "number" => b}},
          {matrix, %{"row_id" => Enum.at(row_ids, 2), "number" => c}}
        ])
      end

      {:ok, lv, _html} =
        results(ctx.conn, ctx.survey, %{"tab" => "questions", "question_id" => matrix.id})

      html = render(lv)

      assert html =~ "Cronbach"
      assert html =~ "Alpha without it"
      assert html =~ "Clear"
      assert has_element?(lv, "#likert-chart")
    end
  end

  describe "compare tab" do
    setup ctx do
      question = add(ctx.survey, :scale)
      a = insert(:cohort, name: "Group A")
      b = insert(:cohort, name: "Group B")

      for n <- [5, 5, 4, 5],
          do: respond(ctx.survey, [{question, %{"number" => n}}], cohort_id: a.id)

      for n <- [2, 1, 2, 1],
          do: respond(ctx.survey, [{question, %{"number" => n}}], cohort_id: b.id)

      %{question: question, cohort_a: a, cohort_b: b}
    end

    test "shows both tests side by side with a plain-language verdict", ctx do
      {:ok, lv, _html} = results(ctx.conn, ctx.survey, %{"tab" => "compare"})

      html = render(lv)

      assert html =~ "t test (Welch)"
      assert html =~ "Mann-Whitney U"
      assert html =~ "would be unlikely if the groups really answered the same way"
      assert html =~ "Effect size"
      assert has_element?(lv, "#group-means-chart")
    end

    test "names the cohorts, and they are groups, not people", ctx do
      {:ok, _lv, html} = results(ctx.conn, ctx.survey, %{"tab" => "compare"})

      assert html =~ "Group A"
      assert html =~ "Group B"
    end

    test "the cohort filter narrows every figure", ctx do
      {:ok, lv, _html} = results(ctx.conn, ctx.survey, %{"tab" => "questions"})

      lv
      |> form("form[phx-change=filter_cohort]", %{"cohort_id" => ctx.cohort_a.id})
      |> render_change()

      assert_patched(
        lv,
        ~p"/studio/surveys/#{ctx.survey.id}/results?#{%{"tab" => "questions", "cohort_id" => ctx.cohort_a.id}}"
      )

      # Group A answered 4 and 5 only, so the mean is above 4.
      {:ok, scoped} = Surveys.question_descriptives(ctx.question, cohort_id: ctx.cohort_a.id)
      assert scoped.n == 4
      assert scoped.mean > 4.0
    end

    test "says so when only one group has answered", ctx do
      lone = insert(:survey, owner_id: ctx.user.id, status: :published)
      question = add(lone, :scale)
      cohort = insert(:cohort)

      for n <- [4, 5], do: respond(lone, [{question, %{"number" => n}}], cohort_id: cohort.id)

      {:ok, _lv, html} = results(ctx.conn, lone, %{"tab" => "compare"})

      assert html =~ "nothing to compare"
    end
  end

  describe "identity" do
    test "a cohort respondent's verbatim names the cohort, never the person", ctx do
      question = add(ctx.survey, :open_text)
      cohort = insert(:cohort, name: "Group A")

      student = insert(:account, login: "quiet_student")
      insert(:profile, owner: student, first_name: "Anna", last_name: "Petrova")

      respond(ctx.survey, [{question, %{"text" => "The labs were the best part"}}],
        cohort_id: cohort.id,
        account_id: student.id
      )

      {:ok, _lv, html} = results(ctx.conn, ctx.survey, %{"tab" => "verbatims"})

      assert html =~ "The labs were the best part"
      assert html =~ "Group A"

      # The promise the survey makes. Attributes included: an account id in a
      # phx-value would leak just as surely as one in the text.
      refute html =~ "Anna"
      refute html =~ "Petrova"
      refute html =~ "quiet_student"
      refute html =~ student.id
    end

    test "an individually enrolled respondent is named, having no group to hide in", ctx do
      question = add(ctx.survey, :open_text)

      student = insert(:account)
      insert(:profile, owner: student, first_name: "Boris", last_name: "Ivanov")

      respond(ctx.survey, [{question, %{"text" => "More reading please"}}],
        cohort_id: nil,
        account_id: student.id
      )

      {:ok, _lv, html} = results(ctx.conn, ctx.survey, %{"tab" => "verbatims"})

      assert html =~ "More reading please"
      assert html =~ "Boris"
    end

    test "no account id reaches the markup anywhere on the screen", ctx do
      question = add(ctx.survey, :scale)
      cohort = insert(:cohort, name: "Group A")

      students = for _ <- 1..3, do: insert(:account)

      for {student, n} <- Enum.zip(students, [5, 3, 1]) do
        respond(ctx.survey, [{question, %{"number" => n}}],
          cohort_id: cohort.id,
          account_id: student.id
        )
      end

      for tab <- ~w(overview questions compare verbatims) do
        {:ok, _lv, html} = results(ctx.conn, ctx.survey, %{"tab" => tab})

        for student <- students do
          refute html =~ student.id, "#{tab} leaked an account id"
          refute html =~ student.login, "#{tab} leaked a login"
        end
      end
    end
  end

  describe "tabs" do
    test "switching tabs round-trips through the URL so a view can be sent on", ctx do
      add(ctx.survey, :scale)
      respond(ctx.survey, [])

      {:ok, lv, _html} = results(ctx.conn, ctx.survey)

      lv |> element("#tab-compare") |> render_click()

      assert_patched(lv, ~p"/studio/surveys/#{ctx.survey.id}/results?#{%{"tab" => "compare"}}")
    end

    test "an unknown tab falls back to the overview rather than erroring", ctx do
      add(ctx.survey, :scale)
      respond(ctx.survey, [])

      {:ok, lv, _html} = results(ctx.conn, ctx.survey, %{"tab" => "nonsense"})

      assert has_element?(lv, "#tab-overview.tab-active")
    end
  end
end
