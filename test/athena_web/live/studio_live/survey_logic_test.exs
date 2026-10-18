defmodule AthenaWeb.StudioLive.SurveyLogicTest do
  @moduledoc """
  The logic editor and the in-builder preview.

  The preview tests matter most: the preview is only worth having if it
  branches exactly as the player will, so they check that a condition fires
  on a real answer derived through the real answer changeset, and that
  nothing reaches the database.
  """
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Surveys
  alias Athena.Surveys.{SurveyAnswer, SurveyBranch, SurveyResponse}

  setup %{conn: conn} do
    user =
      insert(:account,
        role:
          insert(:role,
            permissions: ["surveys.read", "surveys.create", "surveys.update"]
          )
      )

    conn = init_test_session(conn, %{"account_id" => user.id})
    {:ok, survey} = Surveys.create_survey(user, %{"title" => "Feedback"})

    %{conn: conn, user: user, survey: survey}
  end

  defp builder(conn, survey), do: live(conn, ~p"/studio/surveys/#{survey.id}/builder")

  defp with_questions(survey, types) do
    for type <- types do
      {:ok, question} = Surveys.add_question(survey, type)
      question
    end
  end

  defp first_rule(survey), do: survey.id |> Surveys.list_branches() |> hd()

  # The builder page behind the modal lists every question's prompt in its
  # collapsed card, so a page-wide assertion about what the preview shows
  # would pass no matter which question it is on.
  defp preview_html(lv), do: lv |> element("#preview-modal") |> render()

  describe "adding and removing rules" do
    test "a new rule is valid the moment it is created", %{conn: conn, survey: survey} do
      [q1, _q2] = with_questions(survey, [:scale, :open_text])
      {:ok, lv, _html} = builder(conn, survey)

      lv |> element("#expand-#{q1.id}") |> render_click()
      lv |> element("#add-rule-#{q1.id}") |> render_click()

      rule = first_rule(survey)

      # Saved, not a blank form waiting to be filled in.
      assert rule.question_id == q1.id
      assert rule.action == :end_survey
      assert [clause] = rule.condition.clauses
      assert clause.question_id == q1.id
      assert clause.op == :answered
      assert clause.id
    end

    test "a rule is deleted and the gap closes", %{conn: conn, survey: survey} do
      [q1, _q2] = with_questions(survey, [:scale, :open_text])
      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#expand-#{q1.id}") |> render_click()

      for _ <- 1..3, do: lv |> element("#add-rule-#{q1.id}") |> render_click()
      [a, _b, _c] = Surveys.list_branches_for_question(q1.id)

      lv |> element("#delete-rule-#{a.id}") |> render_click()

      remaining = Surveys.list_branches_for_question(q1.id)
      assert length(remaining) == 2
      assert Enum.map(remaining, & &1.position) == [0, 1]
    end

    test "the last question offers no branching, having nowhere to send anyone", %{
      conn: conn,
      survey: survey
    } do
      [_q1, q2] = with_questions(survey, [:scale, :open_text])
      {:ok, lv, _html} = builder(conn, survey)

      lv |> element("#expand-#{q2.id}") |> render_click()

      refute has_element?(lv, "#add-rule-#{q2.id}")
    end

    test "reordering rules decides which one wins", %{conn: conn, survey: survey} do
      [q1, _q2] = with_questions(survey, [:scale, :open_text])
      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#expand-#{q1.id}") |> render_click()

      for _ <- 1..3, do: lv |> element("#add-rule-#{q1.id}") |> render_click()
      [a, b, c] = Surveys.list_branches_for_question(q1.id)

      render_hook(lv, "reorder_rules", %{
        "questionId" => q1.id,
        "id" => c.id,
        "new_index" => 0
      })

      assert Enum.map(Surveys.list_branches_for_question(q1.id), & &1.id) == [c.id, a.id, b.id]
    end
  end

  describe "editing a rule" do
    setup %{conn: conn, survey: survey} do
      [q1, q2, q3] = with_questions(survey, [:scale, :open_text, :numeric])
      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#expand-#{q1.id}") |> render_click()
      lv |> element("#add-rule-#{q1.id}") |> render_click()

      %{lv: lv, q1: q1, q2: q2, q3: q3, rule: first_rule(survey), survey: survey}
    end

    test "the action and its target are saved", ctx do
      render_change(ctx.lv, "update_rule", %{
        "rule_id" => ctx.rule.id,
        "action" => "goto_question",
        "target_question_id" => ctx.q3.id
      })

      rule = Surveys.get_branch(ctx.rule.id)
      assert rule.action == :goto_question
      assert rule.target_question_id == ctx.q3.id
    end

    test "switching the action clears the target the old one used", ctx do
      render_change(ctx.lv, "update_rule", %{
        "rule_id" => ctx.rule.id,
        "action" => "goto_question",
        "target_question_id" => ctx.q3.id
      })

      render_change(ctx.lv, "update_rule", %{"rule_id" => ctx.rule.id, "action" => "end_survey"})

      rule = Surveys.get_branch(ctx.rule.id)
      assert rule.action == :end_survey
      assert rule.target_question_id == nil
    end

    test "a numeric operand is parsed, not stored as a string", ctx do
      render_change(ctx.lv, "update_clause", %{
        "rule_id" => ctx.rule.id,
        "clause_id" => hd(ctx.rule.condition.clauses).id,
        "question_id" => ctx.q1.id,
        "op" => "lte",
        "value" => %{"number" => "2"}
      })

      [clause] = Surveys.get_branch(ctx.rule.id).condition.clauses

      # A rule comparing against "2" would never match an answer holding 2.
      assert clause.op == :lte
      assert clause.value == %{"number" => 2}
    end

    test "changing the tested question resets the operand", ctx do
      clause_id = hd(ctx.rule.condition.clauses).id

      render_change(ctx.lv, "update_clause", %{
        "rule_id" => ctx.rule.id,
        "clause_id" => clause_id,
        "question_id" => ctx.q1.id,
        "op" => "lte",
        "value" => %{"number" => "2"}
      })

      # The browser still posts the old numeric input while re-rendering, and
      # an operand left over from a different question would be read as
      # malformed - so the rule would silently never match.
      render_change(ctx.lv, "update_clause", %{
        "rule_id" => ctx.rule.id,
        "clause_id" => clause_id,
        "question_id" => ctx.q2.id,
        "op" => "lte",
        "value" => %{"number" => "2"}
      })

      [clause] = Surveys.get_branch(ctx.rule.id).condition.clauses
      assert clause.question_id == ctx.q2.id
      assert clause.value == %{}
    end

    test "changing to an operator needing a different operand resets it too", ctx do
      clause_id = hd(ctx.rule.condition.clauses).id

      render_change(ctx.lv, "update_clause", %{
        "rule_id" => ctx.rule.id,
        "clause_id" => clause_id,
        "question_id" => ctx.q1.id,
        "op" => "lte",
        "value" => %{"number" => "2"}
      })

      render_change(ctx.lv, "update_clause", %{
        "rule_id" => ctx.rule.id,
        "clause_id" => clause_id,
        "question_id" => ctx.q1.id,
        "op" => "between",
        "value" => %{"number" => "2"}
      })

      [clause] = Surveys.get_branch(ctx.rule.id).condition.clauses
      assert clause.op == :between
      assert clause.value == %{}
    end

    test "clauses are added, combined with and/or, and removed by id", ctx do
      render_click(ctx.lv, "add_clause", %{"rule_id" => ctx.rule.id})

      clauses = Surveys.get_branch(ctx.rule.id).condition.clauses
      assert length(clauses) == 2
      assert Enum.all?(clauses, & &1.id)

      render_click(ctx.lv, "toggle_rule_logic", %{"rule_id" => ctx.rule.id})
      assert Surveys.get_branch(ctx.rule.id).condition.logic == :or

      render_click(ctx.lv, "toggle_rule_logic", %{"rule_id" => ctx.rule.id})
      assert Surveys.get_branch(ctx.rule.id).condition.logic == :and

      target = Enum.at(clauses, 1)
      render_click(ctx.lv, "remove_clause", %{"rule_id" => ctx.rule.id, "clause_id" => target.id})

      remaining = Surveys.get_branch(ctx.rule.id).condition.clauses
      assert length(remaining) == 1
      refute Enum.any?(remaining, &(&1.id == target.id))
    end

    test "editing one clause leaves its siblings alone", ctx do
      render_click(ctx.lv, "add_clause", %{"rule_id" => ctx.rule.id})
      [first, second] = Surveys.get_branch(ctx.rule.id).condition.clauses

      render_change(ctx.lv, "update_clause", %{
        "rule_id" => ctx.rule.id,
        "clause_id" => second.id,
        "question_id" => ctx.q1.id,
        "op" => "gte",
        "value" => %{"number" => "4"}
      })

      [kept, changed] = Surveys.get_branch(ctx.rule.id).condition.clauses

      assert kept.id == first.id
      assert kept.op == first.op
      assert changed.op == :gte
    end
  end

  describe "the logic check panel" do
    test "reports sound logic", %{conn: conn, survey: survey} do
      [q1, _q2] = with_questions(survey, [:scale, :open_text])
      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#expand-#{q1.id}") |> render_click()
      lv |> element("#add-rule-#{q1.id}") |> render_click()

      html = lv |> element("#toggle-logic") |> render_click()

      assert html =~ "logic is sound"
    end

    test "names a backward jump and counts it in the button", %{conn: conn, survey: survey} do
      [q1, q2] = with_questions(survey, [:scale, :open_text])

      # Built directly: the editor only offers forward targets, so a backward
      # one can only arrive from older data or another client.
      insert(:survey_branch,
        survey: survey,
        question: q2,
        action: :goto_question,
        target_question_id: q1.id,
        condition: %Athena.Surveys.BranchCondition{
          logic: :and,
          clauses: [
            %Athena.Surveys.BranchClause{
              id: Ecto.UUID.generate(),
              question_id: q2.id,
              op: :answered,
              value: %{}
            }
          ]
        }
      )

      {:ok, lv, html} = builder(conn, survey)

      assert html =~ "logic issue"

      panel = lv |> element("#toggle-logic") |> render_click()
      assert panel =~ "jumps backwards"
      assert panel =~ "can loop"
    end

    test "the flow outline says where each answer leads", %{conn: conn, survey: survey} do
      [q1, q2] = with_questions(survey, [:scale, :open_text])
      {:ok, _} = Surveys.update_question(q1, %{"body" => tiptap_doc("Rate the pace")})
      {:ok, _} = Surveys.update_question(q2, %{"body" => tiptap_doc("Anything else?")})

      {:ok, lv, _html} = builder(conn, survey)
      html = lv |> element("#toggle-logic") |> render_click()

      assert html =~ "Flow outline"
      assert html =~ "Rate the pace"
      assert html =~ "otherwise"
      assert html =~ "Anything else?"
    end
  end

  describe "the preview" do
    setup %{conn: conn, survey: survey} do
      [q1, q2, q3] = with_questions(survey, [:scale, :open_text, :numeric])

      {:ok, _} = Surveys.update_question(q1, %{"body" => tiptap_doc("Rate the pace")})
      {:ok, _} = Surveys.update_question(q2, %{"body" => tiptap_doc("What would you change?")})
      {:ok, _} = Surveys.update_question(q3, %{"body" => tiptap_doc("Hours per week?")})

      %{survey: survey, q1: q1, q2: q2, q3: q3, conn: conn}
    end

    test "walks the survey without touching the database", ctx do
      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)

      lv |> element("#start-preview") |> render_click()
      assert preview_html(lv) =~ "Rate the pace"
      assert preview_html(lv) =~ "Nothing here is saved"

      render_change(lv, "preview_answer", %{
        "question_id" => ctx.q1.id,
        "value" => %{"number" => "4"}
      })

      lv |> element("#preview-next") |> render_click()
      assert preview_html(lv) =~ "What would you change?"

      # The whole point: a preview that wrote rows would pollute the results.
      assert Athena.Repo.aggregate(SurveyResponse, :count) == 0
      assert Athena.Repo.aggregate(SurveyAnswer, :count) == 0
    end

    test "a condition fires on a real answer, so a branch here is a branch there", ctx do
      {:ok, _rule} =
        Surveys.add_branch(ctx.survey, ctx.q1, %{
          "action" => "goto_question",
          "target_question_id" => ctx.q3.id,
          "condition" => %{
            "logic" => "and",
            "clauses" => [
              %{
                "id" => Ecto.UUID.generate(),
                "question_id" => ctx.q1.id,
                "op" => "lte",
                "value" => %{"number" => 2}
              }
            ]
          }
        })

      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)
      lv |> element("#start-preview") |> render_click()

      render_change(lv, "preview_answer", %{
        "question_id" => ctx.q1.id,
        "value" => %{"number" => "1"}
      })

      lv |> element("#preview-next") |> render_click()
      html = preview_html(lv)

      assert html =~ "Hours per week?"
      refute html =~ "What would you change?"
    end

    test "a high answer falls through to the next question", ctx do
      {:ok, _rule} =
        Surveys.add_branch(ctx.survey, ctx.q1, %{
          "action" => "goto_question",
          "target_question_id" => ctx.q3.id,
          "condition" => %{
            "logic" => "and",
            "clauses" => [
              %{
                "id" => Ecto.UUID.generate(),
                "question_id" => ctx.q1.id,
                "op" => "lte",
                "value" => %{"number" => 2}
              }
            ]
          }
        })

      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)
      lv |> element("#start-preview") |> render_click()

      render_change(lv, "preview_answer", %{
        "question_id" => ctx.q1.id,
        "value" => %{"number" => "5"}
      })

      lv |> element("#preview-next") |> render_click()
      assert preview_html(lv) =~ "What would you change?"
    end

    test "an invalid answer is ignored rather than stored as nothing", ctx do
      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)
      lv |> element("#start-preview") |> render_click()

      render_change(lv, "preview_answer", %{
        "question_id" => ctx.q1.id,
        "value" => %{"number" => "four"}
      })

      # Nothing was recorded, so the rule-free fall-through still applies.
      lv |> element("#preview-next") |> render_click()
      assert preview_html(lv) =~ "What would you change?"
    end

    test "back retraces the path actually taken", ctx do
      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)
      lv |> element("#start-preview") |> render_click()

      refute has_element?(lv, "#preview-back")

      lv |> element("#preview-next") |> render_click()
      lv |> element("#preview-back") |> render_click()

      assert preview_html(lv) =~ "Rate the pace"
    end

    test "answers are remembered when stepping back", ctx do
      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)
      lv |> element("#start-preview") |> render_click()

      render_change(lv, "preview_answer", %{
        "question_id" => ctx.q1.id,
        "value" => %{"number" => "4"}
      })

      lv |> element("#preview-next") |> render_click()
      lv |> element("#preview-back") |> render_click()

      assert preview_html(lv) =~ ~r/value="4"[^>]*checked/
    end

    test "reaching the end says so and counts the path", ctx do
      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)
      lv |> element("#start-preview") |> render_click()

      for _ <- 1..3, do: lv |> element("#preview-next") |> render_click()

      assert has_element?(lv, "#preview-finished")
    end

    test "starting over clears the answers", ctx do
      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)
      lv |> element("#start-preview") |> render_click()

      render_change(lv, "preview_answer", %{
        "question_id" => ctx.q1.id,
        "value" => %{"number" => "4"}
      })

      lv |> element("#preview-next") |> render_click()
      lv |> element("#preview-restart") |> render_click()

      assert preview_html(lv) =~ "Rate the pace"
      refute preview_html(lv) =~ ~r/value="4"[^>]*checked/
    end

    test "closing dismisses it", ctx do
      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)
      lv |> element("#start-preview") |> render_click()

      lv |> element("#close-preview") |> render_click()

      refute has_element?(lv, "#preview-modal")
    end

    test "a ranking answer records the dragged order", %{conn: conn, user: user} do
      {:ok, survey} = Surveys.create_survey(user, %{"title" => "Priorities"})
      {:ok, ranking} = Surveys.add_question(survey, :ranking)
      {:ok, _tail} = Surveys.add_question(survey, :open_text)

      [first, second] = Enum.map(ranking.config["items"], & &1["id"])

      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#start-preview") |> render_click()

      render_hook(lv, "survey_rank", %{
        "questionId" => ranking.id,
        "id" => second,
        "new_index" => 0
      })

      # The dragged item is now first, and nothing was written.
      assert preview_html(lv) =~ ~r/rank-#{ranking.id}-#{second}.*rank-#{ranking.id}-#{first}/s
      assert Athena.Repo.aggregate(SurveyAnswer, :count) == 0
    end
  end

  describe "the structural lock covers logic too" do
    test "rules cannot be added or edited once answers exist", %{conn: conn, user: user} do
      {:ok, survey} = Surveys.create_survey(user, %{"title" => "Locked"})
      [q1, _q2] = with_questions(survey, [:scale, :open_text])

      {:ok, rule} =
        Surveys.add_branch(survey, q1, %{
          "action" => "end_survey",
          "condition" => %{
            "logic" => "and",
            "clauses" => [
              %{"id" => Ecto.UUID.generate(), "question_id" => q1.id, "op" => "answered"}
            ]
          }
        })

      {:ok, published} = Surveys.publish_survey(survey)
      insert(:survey_response, survey: published)

      {:ok, lv, _html} = builder(conn, published)

      html = render_click(lv, "add_rule", %{"question_id" => q1.id})
      assert html =~ "already has responses"
      assert Athena.Repo.aggregate(SurveyBranch, :count) == 1

      render_click(lv, "delete_rule", %{"rule_id" => rule.id})
      assert Athena.Repo.aggregate(SurveyBranch, :count) == 1

      render_change(lv, "update_rule", %{"rule_id" => rule.id, "action" => "goto_page"})
      assert Surveys.get_branch(rule.id).action == :end_survey
    end

    test "the preview still works on a locked survey", %{conn: conn, user: user} do
      {:ok, survey} = Surveys.create_survey(user, %{"title" => "Locked"})
      with_questions(survey, [:scale, :open_text])
      {:ok, published} = Surveys.publish_survey(survey)
      insert(:survey_response, survey: published)

      {:ok, lv, _html} = builder(conn, published)

      # Reading is not editing: an author must be able to see what students
      # are being asked even when the structure is frozen.
      lv |> element("#start-preview") |> render_click()
      assert preview_html(lv) =~ "Nothing here is saved"
    end
  end
end
