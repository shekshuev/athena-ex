defmodule AthenaWeb.StudioLive.SurveyBuilderTest do
  @moduledoc """
  The builder. Driven through the element ids the templates declare rather
  than through raw HTML, so a restyle does not break the suite.
  """
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Surveys

  defp sign_in(conn, permissions) do
    user = insert(:account, role: insert(:role, permissions: permissions))
    {init_test_session(conn, %{"account_id" => user.id}), user}
  end

  defp author(conn) do
    sign_in(conn, [
      "surveys.read",
      "surveys.create",
      "surveys.update",
      "surveys.delete",
      "surveys.publish"
    ])
  end

  setup %{conn: conn} do
    {conn, user} = author(conn)
    {:ok, survey} = Surveys.create_survey(user, %{"title" => "Mid-course feedback"})

    %{conn: conn, user: user, survey: survey}
  end

  defp builder(conn, survey), do: live(conn, ~p"/studio/surveys/#{survey.id}/builder")

  describe "access" do
    test "a user without surveys.update is turned away", %{conn: conn, user: user} do
      {:ok, survey} = Surveys.create_survey(user, %{"title" => "Feedback"})
      {reader_conn, _reader} = sign_in(conn, ["surveys.read"])

      assert {:error, {:redirect, %{to: "/dashboard"}}} = builder(reader_conn, survey)
    end

    test "own_only keeps an author out of someone else's survey", %{conn: conn} do
      role =
        insert(:role,
          permissions: ["surveys.read", "surveys.update"],
          policies: %{"surveys.update" => ["own_only"]}
        )

      intruder = insert(:account, role: role)
      stranger_survey = insert(:survey, owner_id: Ecto.UUID.generate())
      conn = init_test_session(conn, %{"account_id" => intruder.id})

      assert {:error, {:live_redirect, %{to: "/studio/surveys", flash: flash}}} =
               builder(conn, stranger_survey)

      assert flash["error"] =~ "cannot edit"
    end

    test "a missing survey redirects to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/studio/surveys"}}} =
               live(conn, ~p"/studio/surveys/#{Ecto.UUID.generate()}/builder")
    end
  end

  describe "adding questions" do
    test "every type can be added and shows up as a card", %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)

      for type <- Surveys.QuestionTypes.all() do
        lv |> element("#add-#{type}") |> render_click()
      end

      questions = Surveys.list_questions(survey.id)

      assert length(questions) == length(Surveys.QuestionTypes.all())
      assert Enum.map(questions, & &1.type) == Surveys.QuestionTypes.all()

      for question <- questions do
        assert has_element?(lv, "#question-#{question.id}")
      end
    end

    test "a newly added question opens expanded, ready to edit", %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)

      lv |> element("#add-scale") |> render_click()

      [question] = Surveys.list_questions(survey.id)

      assert has_element?(lv, "#prompt-editor-#{question.id}")
    end

    test "an empty survey shows an empty state instead of a bare page", %{
      conn: conn,
      survey: survey
    } do
      {:ok, _lv, html} = builder(conn, survey)

      assert html =~ "No questions yet"
    end
  end

  describe "editing a question" do
    setup %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#add-single_choice") |> render_click()
      [question] = Surveys.list_questions(survey.id)

      %{lv: lv, question: question}
    end

    test "the prompt is saved from the editor hook", ctx do
      body = tiptap_doc("How was the pace?")

      render_hook(ctx.lv, "update_prompt", %{"id" => ctx.question.id, "content" => body})

      assert Surveys.get_question(ctx.question.id).body == body
    end

    test "helper text is saved", ctx do
      ctx.lv
      |> form("form[phx-change=update_help_text]", %{
        "question_id" => ctx.question.id,
        "help_text" => "Be honest"
      })
      |> render_change()

      assert Surveys.get_question(ctx.question.id).help_text == "Be honest"
    end

    test "required toggles", ctx do
      refute ctx.question.required

      render_click(ctx.lv, "toggle_required", %{"question_id" => ctx.question.id})
      assert Surveys.get_question(ctx.question.id).required

      render_click(ctx.lv, "toggle_required", %{"question_id" => ctx.question.id})
      refute Surveys.get_question(ctx.question.id).required
    end

    test "options are added, renamed and removed by id", ctx do
      render_click(ctx.lv, "add_list_item", %{
        "question_id" => ctx.question.id,
        "list_key" => "options"
      })

      options = Surveys.get_question(ctx.question.id).config["options"]
      assert length(options) == 3

      target = Enum.at(options, 1)

      render_change(ctx.lv, "update_list_item", %{
        "question_id" => ctx.question.id,
        "list_key" => "options",
        "item_id" => target["id"],
        "field" => "text",
        "text" => "It was fine"
      })

      renamed = Surveys.get_question(ctx.question.id).config["options"]
      assert Enum.at(renamed, 1)["text"] == "It was fine"
      # Renaming by id must not disturb its neighbours or their order.
      assert Enum.map(renamed, & &1["id"]) == Enum.map(options, & &1["id"])

      render_click(ctx.lv, "remove_list_item", %{
        "question_id" => ctx.question.id,
        "list_key" => "options",
        "item_id" => target["id"]
      })

      remaining = Surveys.get_question(ctx.question.id).config["options"]
      assert length(remaining) == 2
      refute Enum.any?(remaining, &(&1["id"] == target["id"]))
    end

    test "scalar config fields are cast from form strings", ctx do
      render_click(ctx.lv, "add_question", %{"type" => "scale"})

      scale = Surveys.list_questions(ctx.question.survey_id) |> List.last()

      render_change(ctx.lv, "update_config", %{
        "question_id" => scale.id,
        "config" => %{"min" => "1", "max" => "7", "min_label" => "Never"}
      })

      config = Surveys.get_question(scale.id).config

      # Arrives as "7", stored as 7 - the config changeset casts it, so the
      # statistics never see a numeric field holding a string.
      assert config["max"] == 7
      assert config["min_label"] == "Never"
    end

    test "an invalid config change is reported and nothing is saved", ctx do
      render_click(ctx.lv, "add_question", %{"type" => "scale"})
      scale = Surveys.list_questions(ctx.question.survey_id) |> List.last()

      html =
        render_change(ctx.lv, "update_config", %{
          "question_id" => scale.id,
          "config" => %{"min" => "9", "max" => "2"}
        })

      assert html =~ "max"
      assert Surveys.get_question(scale.id).config["max"] == 5
    end

    test "config flags toggle", ctx do
      render_click(ctx.lv, "toggle_config_flag", %{
        "question_id" => ctx.question.id,
        "key" => "other_allowed"
      })

      assert Surveys.get_question(ctx.question.id).config["other_allowed"] == true
    end
  end

  describe "changing a question's type" do
    test "replaces the config with the new type's defaults", %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#add-scale") |> render_click()
      [question] = Surveys.list_questions(survey.id)

      render_click(lv, "change_type", %{"question_id" => question.id, "type" => "single_choice"})

      changed = Surveys.get_question(question.id)
      assert changed.type == :single_choice
      assert length(changed.config["options"]) == 2
    end

    test "an unknown type is refused", %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#add-scale") |> render_click()
      [question] = Surveys.list_questions(survey.id)

      html = render_click(lv, "change_type", %{"question_id" => question.id, "type" => "haiku"})

      assert html =~ "Unknown question type"
      assert Surveys.get_question(question.id).type == :scale
    end
  end

  describe "duplicating, deleting and reordering" do
    setup %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)

      for type <- ["scale", "open_text", "numeric"] do
        lv |> element("#add-#{type}") |> render_click()
      end

      %{lv: lv, questions: Surveys.list_questions(survey.id)}
    end

    test "duplicating inserts the copy right after the original", ctx do
      [first | _] = ctx.questions

      render_click(ctx.lv, "duplicate_question", %{"question_id" => first.id})

      types = ctx.questions |> hd() |> Map.get(:survey_id) |> Surveys.list_questions()

      assert Enum.map(types, & &1.type) == [:scale, :scale, :open_text, :numeric]
    end

    test "deleting asks first, then removes", ctx do
      [first | _] = ctx.questions

      ctx.lv |> element("#expand-#{first.id}") |> render_click()
      ctx.lv |> element("#delete-#{first.id}") |> render_click()
      assert has_element?(ctx.lv, "#delete-question-modal.modal-open")

      render_click(ctx.lv, "confirm_delete", %{})

      remaining = Surveys.list_questions(first.survey_id)
      assert length(remaining) == 2
      refute Enum.any?(remaining, &(&1.id == first.id))
    end

    test "cancelling the delete keeps the question", ctx do
      [first | _] = ctx.questions

      ctx.lv |> element("#expand-#{first.id}") |> render_click()
      ctx.lv |> element("#delete-#{first.id}") |> render_click()
      render_click(ctx.lv, "cancel_delete", %{})

      assert length(Surveys.list_questions(first.survey_id)) == 3
      assert Surveys.get_question(first.id)
    end

    test "the inline panel adds below the question being edited", ctx do
      [a, b, _c] = ctx.questions

      ctx.lv |> element("#expand-#{a.id}") |> render_click()
      ctx.lv |> element("#inline-add-nps-#{a.id}") |> render_click()

      questions = Surveys.list_questions(a.survey_id)

      # Not at the end: the inline control exists so an author can grow the
      # survey where they are looking.
      assert Enum.map(questions, & &1.type) == [:scale, :nps, :open_text, :numeric]
      assert Enum.at(questions, 1).id != b.id
    end

    test "the bottom panel appends", ctx do
      ctx.lv |> element("#add-nps") |> render_click()

      assert Surveys.list_questions(hd(ctx.questions).survey_id)
             |> List.last()
             |> Map.get(:type) == :nps
    end

    test "the gutter arrows move a question one place", ctx do
      [a, b, c] = ctx.questions

      # Drag needs a mouse; these do not.
      render_click(ctx.lv, "move_question_down", %{"question_id" => a.id})
      assert Enum.map(Surveys.list_questions(a.survey_id), & &1.id) == [b.id, a.id, c.id]

      render_click(ctx.lv, "move_question_up", %{"question_id" => a.id})
      assert Enum.map(Surveys.list_questions(a.survey_id), & &1.id) == [a.id, b.id, c.id]
    end

    test "a drag reorder applies the resulting order, not just the move", ctx do
      [a, b, c] = ctx.questions

      # SortableJS reports only {id, new_index}; the resulting order is
      # computed from the list the LiveView holds.
      render_hook(ctx.lv, "reorder", %{"id" => c.id, "new_index" => 0})

      assert Enum.map(Surveys.list_questions(a.survey_id), & &1.id) == [c.id, a.id, b.id]
      assert Enum.map(Surveys.list_questions(a.survey_id), & &1.position) == [0, 1, 2]
    end

    test "a page break starts a new page", ctx do
      ctx.lv |> element("#add-page-break") |> render_click()

      questions = Surveys.list_questions(hd(ctx.questions).survey_id)

      assert Enum.map(questions, & &1.page) == [0, 0, 0, 1]
    end
  end

  describe "publishing" do
    test "a survey with no questions cannot be published", %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)

      html = lv |> element("#publish-survey") |> render_click()

      assert html =~ "Add a question first"
      assert Surveys.get_survey(survey.id).status == :draft
    end

    test "publishing then closing walks the lifecycle", %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)
      lv |> element("#add-scale") |> render_click()

      lv |> element("#publish-survey") |> render_click()
      assert Surveys.get_survey(survey.id).status == :published

      lv |> element("#close-survey") |> render_click()
      assert Surveys.get_survey(survey.id).status == :closed
    end

    test "the title is renamed inline", %{conn: conn, survey: survey} do
      {:ok, lv, _html} = builder(conn, survey)

      lv
      |> form("form[phx-change=rename_survey]", %{"title" => "End of term feedback"})
      |> render_change()

      assert Surveys.get_survey(survey.id).title == "End of term feedback"
    end
  end

  describe "where it is used" do
    test "a published survey in no course says nobody can answer it", ctx do
      {:ok, _question} = Surveys.add_question(ctx.survey, :scale)
      {:ok, published} = Surveys.publish_survey(ctx.survey)

      {:ok, lv, html} = builder(ctx.conn, published)

      # A survey reaches students through a block in a course and nowhere
      # else, and the symptom of a missing block is otherwise just silence.
      assert has_element?(lv, "#unused-banner")
      assert html =~ "not in any course"
      refute has_element?(lv, "#usage-panel")
    end

    test "a draft is not flagged: it is not meant to be answerable yet", ctx do
      {:ok, _question} = Surveys.add_question(ctx.survey, :scale)

      {:ok, lv, _html} = builder(ctx.conn, ctx.survey)

      refute has_element?(lv, "#unused-banner")
    end

    test "once placed, it lists the courses students reach it through", ctx do
      {:ok, _question} = Surveys.add_question(ctx.survey, :scale)
      {:ok, published} = Surveys.publish_survey(ctx.survey)

      course = insert(:course, title: "Databases", status: :published)
      section = insert(:section, course: course, title: "Week 1")

      insert(:block,
        section: section,
        type: :survey,
        content: %{"survey_id" => published.id}
      )

      {:ok, lv, html} = builder(ctx.conn, published)

      refute has_element?(lv, "#unused-banner")
      assert has_element?(lv, "#usage-panel")
      assert html =~ "Databases"
      assert html =~ "Week 1"
    end

    test "flags a placement in a course that is not published either", ctx do
      {:ok, _question} = Surveys.add_question(ctx.survey, :scale)
      {:ok, published} = Surveys.publish_survey(ctx.survey)

      course = insert(:course, title: "Draft course", status: :draft)
      section = insert(:section, course: course)

      insert(:block, section: section, type: :survey, content: %{"survey_id" => published.id})

      {:ok, _lv, html} = builder(ctx.conn, published)

      # Placed but still unreachable, for a different reason - worth saying,
      # since the author would otherwise go looking at the survey.
      assert html =~ "course not published"
    end
  end

  describe "the structural lock" do
    setup %{conn: conn, user: user} do
      {:ok, survey} = Surveys.create_survey(user, %{"title" => "Locked"})
      {:ok, question} = Surveys.add_question(survey, :scale)
      {:ok, published} = Surveys.publish_survey(survey)
      insert(:survey_response, survey: published, status: :in_progress)

      {:ok, lv, html} = builder(conn, published)

      %{lv: lv, html: html, survey: published, question: question}
    end

    test "a single partial response locks the questions and says so", ctx do
      assert ctx.html =~ "Questions are locked"
      assert has_element?(ctx.lv, "#locked-banner")
      assert has_element?(ctx.lv, "#duplicate-as-version")
    end

    test "the add-question picker is gone", ctx do
      refute has_element?(ctx.lv, "#add-scale")
    end

    test "the gutter arrows are refused too", ctx do
      render_click(ctx.lv, "move_question_down", %{"question_id" => ctx.question.id})

      assert Surveys.get_question(ctx.question.id).position == 0
    end

    test "a mutating event is refused even if it is sent anyway", ctx do
      # The lock protects already-collected answers, so it is re-checked on
      # the server rather than trusted to a hidden button.
      html = render_click(ctx.lv, "add_question", %{"type" => "scale"})

      assert html =~ "already has responses"
      assert length(Surveys.list_questions(ctx.survey.id)) == 1
    end

    test "editing, deleting and reordering are all refused", ctx do
      render_click(ctx.lv, "toggle_required", %{"question_id" => ctx.question.id})
      refute Surveys.get_question(ctx.question.id).required

      render_click(ctx.lv, "delete_click", %{"question_id" => ctx.question.id})
      render_click(ctx.lv, "confirm_delete", %{})
      assert Surveys.get_question(ctx.question.id)

      render_hook(ctx.lv, "reorder", %{"id" => ctx.question.id, "new_index" => 0})
      assert Surveys.get_question(ctx.question.id).position == 0
    end

    test "duplicating as a version opens an editable draft", ctx do
      {:error, {:live_redirect, %{to: path}}} =
        ctx.lv |> element("#duplicate-as-version") |> render_click()

      assert path =~ ~r"^/studio/surveys/[0-9a-f-]+/builder$"

      copy_id = path |> String.split("/") |> Enum.at(3)
      copy = Surveys.get_survey(copy_id)

      assert copy.status == :draft
      assert copy.source_survey_id == ctx.survey.id
      assert Surveys.survey_editable?(copy)
    end
  end
end
