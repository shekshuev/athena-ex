defmodule AthenaWeb.LearnLive.PlayerTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Content.{CompletionRule, AccessRules}
  alias Athena.Repo

  setup %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})

    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)

    %{conn: conn, user: user, course: course}
  end

  describe "Block Rendering (All Types)" do
    test "renders text, image, video, attachment, and code blocks correctly", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course, title: "All Blocks Section")

      insert(:block,
        section: s1,
        type: :text,
        order: 10,
        content: %{"text" => "Simple paragraph"}
      )

      insert(:block,
        section: s1,
        type: :image,
        order: 20,
        content: %{
          "url" => "http://s3.com/img.jpg",
          "alt" => "A test image"
        }
      )

      insert(:block,
        section: s1,
        type: :video,
        order: 30,
        content: %{
          "url" => "http://s3.com/vid.mp4",
          "poster_url" => "http://s3.com/poster.jpg",
          "controls" => true
        }
      )

      insert(:block,
        section: s1,
        type: :attachment,
        order: 40,
        content: %{
          "description" => %{"text" => "Download this"},
          "files" => [%{"url" => "http://s3.com/doc.pdf", "name" => "doc.pdf", "size" => 1024}]
        }
      )

      insert(:block,
        section: s1,
        type: :code,
        order: 50,
        content: %{
          "language" => "elixir",
          "code" => "IO.puts(:hello_world)"
        }
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Simple paragraph"

      assert html =~ ~s(src="http://s3.com/img.jpg")
      assert html =~ ~s(alt="A test image")

      assert html =~ ~s(src="http://s3.com/vid.mp4")
      assert html =~ ~s(poster="http://s3.com/poster.jpg")

      assert html =~ "doc.pdf"
      assert html =~ "1.0 KB"

      assert html =~ "IO.puts(:hello_world)"
      assert html =~ "editor.ex"
    end

    test "renders quiz_question blocks correctly (all types)", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course, title: "Quiz Section")

      insert(:block,
        section: s1,
        type: :quiz_question,
        order: 10,
        content: %{
          "question_type" => "exact_match",
          "body" => %{"text" => "Find the flag"}
        }
      )

      insert(:block,
        section: s1,
        type: :quiz_question,
        order: 20,
        content: %{
          "question_type" => "single",
          "body" => %{"text" => "Pick one"},
          "options" => [
            %{"id" => "opt1", "text" => "Radio Option 1"},
            %{"id" => "opt2", "text" => "Radio Option 2"}
          ]
        }
      )

      insert(:block,
        section: s1,
        type: :quiz_question,
        order: 30,
        content: %{
          "question_type" => "multiple",
          "body" => %{"text" => "Pick many"},
          "options" => [
            %{"id" => "chk1", "text" => "Check Option A"},
            %{"id" => "chk2", "text" => "Check Option B"}
          ]
        }
      )

      insert(:block,
        section: s1,
        type: :quiz_question,
        order: 40,
        content: %{
          "question_type" => "open",
          "body" => %{"text" => "Write an essay"}
        }
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Enter your answer (flag)..."

      assert html =~ "type=\"radio\""
      assert html =~ "Radio Option 1"
      assert html =~ "Radio Option 2"

      assert html =~ "type=\"checkbox\""
      assert html =~ "Check Option A"
      assert html =~ "Check Option B"

      assert html =~ "<textarea"
      assert html =~ "Type your answer here..."
    end
  end

  describe "Completion Rules (Gates)" do
    test "renders and processes :button gate", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)

      b_gate =
        insert(:block,
          section: s1,
          type: :text,
          completion_rule: %CompletionRule{
            type: :button,
            button_text: "Understood, Sir!"
          }
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Understood, Sir!"
      refute html =~ "Completed"

      html = render_click(lv, "complete_gate", %{"block-id" => b_gate.id})
      assert html =~ "Completed"
    end

    test "renders and processes :submit gate (Task Submission)", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)

      b_gate =
        insert(:block,
          section: s1,
          type: :text,
          completion_rule: %CompletionRule{
            type: :submit
          }
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Task Submission Required"
      assert html =~ "Simulate Pass"
      refute html =~ "Submitted"

      html = render_click(lv, "complete_gate", %{"block-id" => b_gate.id})
      assert html =~ "Submitted"
    end

    test "renders and processes :pass_auto_grade gate", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)

      b_gate =
        insert(:block,
          section: s1,
          type: :code,
          completion_rule: %CompletionRule{
            type: :pass_auto_grade,
            min_score: 95
          }
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Auto-Graded Task"
      assert html =~ "Minimum score required: 95"
      assert html =~ "Simulate Pass"
      refute html =~ "Passed"

      html = render_click(lv, "complete_gate", %{"block-id" => b_gate.id})
      assert html =~ "Passed"
    end

    test "cascading blocks: hides blocks after an uncompleted gate", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)

      insert(:block, section: s1, order: 10, content: %{"text" => "Block 1"})

      b_gate =
        insert(:block, section: s1, order: 20, completion_rule: %CompletionRule{type: :button})

      insert(:block, section: s1, order: 30, content: %{"text" => "Block 3"})

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Block 1"
      refute html =~ "Block 3"
      refute html =~ "Lesson Completed!"

      html = render_click(lv, "complete_gate", %{"block-id" => b_gate.id})

      assert html =~ "Block 3"
      assert html =~ "Lesson Completed!"
    end
  end

  describe "Access and Waterline bounds" do
    test "redirects to dashboard if user has no access to the course", %{conn: conn} do
      unauthorized_user = insert(:account)
      unauthorized_conn = init_test_session(conn, %{"account_id" => unauthorized_user.id})

      course2 = insert(:course)
      s1 = insert(:section, course: course2)

      {:error, {:live_redirect, %{to: "/learn", flash: flash}}} =
        live(unauthorized_conn, ~p"/learn/courses/#{course2.id}/play/#{s1.id}")

      assert flash["error"] == "Access denied."
    end

    test "redirects to syllabus if trying to access a locked section (waterline violation)", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course, order: 1)
      insert(:block, section: s1, completion_rule: %CompletionRule{type: :button})
      s2 = insert(:section, course: course, order: 2)

      {:error, {:live_redirect, %{to: syllabus_path, flash: flash}}} =
        live(conn, ~p"/learn/courses/#{course.id}/play/#{s2.id}")

      assert syllabus_path == "/learn/courses/#{course.id}"
      assert flash["error"] == "You must complete previous lessons first."
    end
  end

  describe "Time-based Access Rules (Visibility)" do
    test "filters out blocks that are locked by future unlock_at or past lock_at", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)

      now = DateTime.utc_now()
      future = DateTime.add(now, 1, :day)
      past = DateTime.add(now, -1, :day)

      insert(:block, section: s1, order: 10, content: %{"text" => "Normal Block"})

      insert(:block,
        section: s1,
        order: 20,
        visibility: :restricted,
        access_rules: %AccessRules{unlock_at: future},
        content: %{"text" => "Future Block"}
      )

      insert(:block,
        section: s1,
        order: 30,
        visibility: :restricted,
        access_rules: %AccessRules{lock_at: past},
        content: %{"text" => "Expired Block"}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Normal Block"
      refute html =~ "Future Block"
      refute html =~ "Expired Block"
    end
  end

  describe "Real-time PubSub Sync" do
    test "boots student to syllabus if instructor restricts the current section", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course, visibility: :public)

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      s1 |> Ecto.Changeset.change(visibility: :hidden) |> Repo.update!()

      send(lv.pid, :refresh_content)

      assert_redirect(lv, "/learn/courses/#{course.id}")
    end
  end
end
