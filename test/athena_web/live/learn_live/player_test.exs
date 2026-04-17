defmodule AthenaWeb.LearnLive.PlayerTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Content.{CompletionRule, AccessRules}

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
        content: %{"url" => "http://s3.com/img.jpg", "alt" => "A test image"}
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
        content: %{"language" => "elixir", "code" => "IO.puts(:hello_world)"}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Simple paragraph"
      assert html =~ ~s(src="http://s3.com/img.jpg")
      assert html =~ ~s(alt="A test image")
      assert html =~ ~s(src="http://s3.com/vid.mp4")
      assert html =~ ~s(poster="http://s3.com/poster.jpg")
      assert html =~ "doc.pdf"
      assert html =~ "IO.puts(:hello_world)"
      assert html =~ "elixir"
    end

    test "renders quiz_question blocks correctly (all types)", %{conn: conn, course: course} do
      s1 = insert(:section, course: course, title: "Quiz Section")

      insert(:block,
        section: s1,
        type: :quiz_question,
        order: 10,
        content: %{"question_type" => "exact_match", "body" => %{"text" => "Find the flag"}}
      )

      insert(:block,
        section: s1,
        type: :quiz_question,
        order: 20,
        content: %{
          "question_type" => "single",
          "body" => %{"text" => "Pick one"},
          "options" => [%{"id" => "opt1", "text" => "Radio Option 1"}]
        }
      )

      insert(:block,
        section: s1,
        type: :quiz_question,
        order: 30,
        content: %{
          "question_type" => "multiple",
          "body" => %{"text" => "Pick many"},
          "options" => [%{"id" => "chk1", "text" => "Check Option A"}]
        }
      )

      insert(:block,
        section: s1,
        type: :quiz_question,
        order: 40,
        content: %{"question_type" => "open", "body" => %{"text" => "Write an essay"}}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Type your answer..."
      assert html =~ "type=\"radio\""
      assert html =~ "Radio Option 1"
      assert html =~ "type=\"checkbox\""
      assert html =~ "Check Option A"
      assert html =~ "<textarea"
    end
  end

  describe "Completion Rules (Gates)" do
    test "renders and processes :button gate", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)

      b_gate =
        insert(:block,
          section: s1,
          type: :text,
          completion_rule: %CompletionRule{type: :button, button_text: "Understood, Sir!"}
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Understood, Sir!"

      html = render_click(lv, "complete_gate", %{"block-id" => b_gate.id})
      assert html =~ "Back to Syllabus"
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

      html = render_click(lv, "complete_gate", %{"block-id" => b_gate.id})

      assert html =~ "Block 3"
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
      s1 = insert(:section, course: course, visibility: :enrolled)

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      Athena.Content.update_section(s1, %{"visibility" => "hidden"})

      Process.sleep(150)

      assert_redirect(lv, "/learn/courses/#{course.id}")
    end
  end

  describe "Quiz Submissions" do
    test "submits exact_match quiz correctly, shows feedback and locks form", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block,
          section: s1,
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "correct_answer" => "flag{123}",
            "general_explanation" => "Hidden in plain sight."
          }
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      refute html =~ "Correct!"
      refute html =~ "Hidden in plain sight."

      html =
        lv
        |> form("#quiz-form-#{block.id}", %{"answer" => "flag{123}"})
        |> render_submit()

      assert html =~ "Correct!"
      assert html =~ "Hidden in plain sight."
      assert html =~ "Submitted"
      refute html =~ "Submit Answer"
    end

    test "submits single choice quiz incorrectly, shows general explanation and locks", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)
      opt1_id = Ecto.UUID.generate()
      opt2_id = Ecto.UUID.generate()

      block =
        insert(:block,
          section: s1,
          type: :quiz_question,
          content: %{
            "question_type" => "single",
            "general_explanation" => "Always pick the right one.",
            "options" => [
              %{"id" => opt1_id, "is_correct" => false},
              %{"id" => opt2_id, "is_correct" => true}
            ]
          }
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      html =
        lv
        |> form("#quiz-form-#{block.id}", %{"answer" => opt1_id})
        |> render_submit()

      assert html =~ "Incorrect."
      assert html =~ "Always pick the right one."
      assert html =~ "Submitted"
      refute html =~ "Submit Answer"
    end

    test "submits open question and sets pending review status", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      html =
        lv
        |> form("#quiz-form-#{block.id}", %{"answer" => "This is my essay."})
        |> render_submit()

      assert html =~ "Pending Review"
      assert html =~ "Submitted"
      refute html =~ "Submit Answer"
    end

    test "pass_auto_grade gate unlocks next block only upon correct submission", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)

      quiz_block =
        insert(:block,
          section: s1,
          order: 10,
          type: :quiz_question,
          completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 100},
          content: %{"question_type" => "exact_match", "correct_answer" => "42"}
        )

      insert(:block, section: s1, order: 20, type: :text, content: %{"text" => "Secret Content"})

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      refute html =~ "Secret Content"

      html =
        lv
        |> form("#quiz-form-#{quiz_block.id}", %{"answer" => "42"})
        |> render_submit()

      assert html =~ "Correct!"
      assert html =~ "Secret Content"
    end

    test "submit gate unlocks next block regardless of correct/incorrect", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)

      quiz_block =
        insert(:block,
          section: s1,
          order: 10,
          type: :quiz_question,
          completion_rule: %CompletionRule{type: :submit},
          content: %{"question_type" => "exact_match", "correct_answer" => "42"}
        )

      insert(:block, section: s1, order: 20, type: :text, content: %{"text" => "Secret Content"})

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      refute html =~ "Secret Content"

      html =
        lv
        |> form("#quiz-form-#{quiz_block.id}", %{"answer" => "wrong"})
        |> render_submit()

      assert html =~ "Incorrect."
      assert html =~ "Secret Content"
    end
  end

  describe "Quiz Exam Block" do
    test "renders initial exam card and starts exam", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)

      block =
        insert(:block,
          section: s1,
          type: :quiz_exam,
          content: %{
            "count" => 15,
            "time_limit" => 45,
            "mandatory_tags" => [],
            "include_tags" => [],
            "exclude_tags" => []
          }
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Final Exam"
      assert html =~ "15 Questions"
      assert html =~ "45 Min"
      assert html =~ "Start Exam"

      lv |> element("button[phx-click='start_exam']") |> render_click()
      assert_redirect(lv, "/learn/courses/#{course.id}/exam/#{block.id}")

      sub = Athena.Repo.one(Athena.Learning.Submission)
      assert sub.status == :pending
      assert sub.block_id == block.id
      assert sub.content["type"] == "quiz_exam"
      assert sub.content["cheat_count"] == 0
    end

    test "renders continue button if exam is pending", %{conn: conn, course: course, user: user} do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :quiz_exam, content: %{"count" => 10})

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        content: %{"type" => "quiz_exam", "cheat_count" => 0, "started_at" => DateTime.utc_now()}
      )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Continue Exam"
      refute html =~ "Start Exam"

      lv |> element("button[phx-click='continue_exam']") |> render_click()
      assert_redirect(lv, "/learn/courses/#{course.id}/exam/#{block.id}")
    end

    test "renders completed state with score if exam is graded successfully", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_exam, content: %{"allowed_blur_attempts" => 3})

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :graded,
        score: 85,
        content: %{"type" => "quiz_exam", "cheat_count" => 1}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Exam Completed"
      assert html =~ "85 / 100"
      refute html =~ "Start Exam"
    end

    test "renders failed state if cheat limit exceeded", %{conn: conn, course: course, user: user} do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_exam, content: %{"allowed_blur_attempts" => 3})

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :graded,
        score: 0,
        content: %{"type" => "quiz_exam", "cheat_count" => 3}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Exam Failed (Violations)"
      refute html =~ "Exam Completed"
      refute html =~ "Start Exam"
    end
  end

  describe "Cohort Schedule Overrides" do
    test "cohort override unlocks a globally locked block", %{
      conn: conn,
      course: course,
      user: user
    } do
      cohort = insert(:cohort)
      insert(:cohort_membership, account_id: user.id, cohort_id: cohort.id)

      s1 = insert(:section, course: course)
      now = DateTime.utc_now()
      future = DateTime.add(now, 1, :day)
      past = DateTime.add(now, -1, :day)

      block =
        insert(:block,
          section: s1,
          visibility: :restricted,
          access_rules: %AccessRules{unlock_at: future},
          content: %{"text" => "Secret Override Content"}
        )

      insert(:cohort_schedule,
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :block,
        resource_id: block.id,
        unlock_at: past
      )

      {:ok, _lv, html} =
        live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}?cohort_id=#{cohort.id}")

      assert html =~ "Secret Override Content"
    end

    test "cohort override locks a globally unlocked block", %{
      conn: conn,
      course: course,
      user: user
    } do
      cohort = insert(:cohort)
      insert(:cohort_membership, account_id: user.id, cohort_id: cohort.id)

      s1 = insert(:section, course: course)
      now = DateTime.utc_now()
      past = DateTime.add(now, -1, :day)
      future = DateTime.add(now, 1, :day)

      block =
        insert(:block,
          section: s1,
          visibility: :restricted,
          access_rules: %AccessRules{unlock_at: past},
          content: %{"text" => "Should Be Hidden"}
        )

      insert(:cohort_schedule,
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :block,
        resource_id: block.id,
        unlock_at: future
      )

      {:ok, _lv, html} =
        live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}?cohort_id=#{cohort.id}")

      refute html =~ "Should Be Hidden"
    end

    test "ignores overrides from other cohorts to prevent context bleeding", %{
      conn: conn,
      course: course,
      user: user
    } do
      cohort1 = insert(:cohort)
      cohort2 = insert(:cohort)
      insert(:cohort_membership, account_id: user.id, cohort_id: cohort1.id)
      insert(:cohort_membership, account_id: user.id, cohort_id: cohort2.id)

      s1 = insert(:section, course: course)

      block =
        insert(:block,
          section: s1,
          visibility: :enrolled,
          content: %{"text" => "Visible Content"}
        )

      insert(:cohort_schedule,
        cohort_id: cohort1.id,
        course_id: course.id,
        resource_type: :block,
        resource_id: block.id,
        visibility: :hidden
      )

      {:ok, _lv, html_c1} =
        live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}?cohort_id=#{cohort1.id}")

      refute html_c1 =~ "Visible Content"

      {:ok, _lv, html_c2} =
        live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}?cohort_id=#{cohort2.id}")

      assert html_c2 =~ "Visible Content"

      {:ok, _lv, html_self} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")
      assert html_self =~ "Visible Content"
    end
  end

  describe "Team Competitions (Shared Progress)" do
    test "team member's completion broadcasts and unlocks next block for teammates", %{
      conn: conn,
      user: user
    } do
      course = insert(:course, type: :competition)
      team = insert(:cohort, type: :team)

      insert(:enrollment, course_id: course.id, cohort_id: team.id)
      insert(:cohort_membership, account_id: user.id, cohort_id: team.id)

      teammate = insert(:account)
      insert(:cohort_membership, account_id: teammate.id, cohort_id: team.id)

      s1 = insert(:section, course: course)
      gate = insert(:block, section: s1, completion_rule: %CompletionRule{type: :button})
      insert(:block, section: s1, content: %{"text" => "Team Unlockable!"})

      {:ok, lv, html} =
        live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}?cohort_id=#{team.id}")

      refute html =~ "Team Unlockable!"

      Athena.Learning.mark_completed(teammate.id, gate.id, team.id)
      Phoenix.PubSub.broadcast(Athena.PubSub, "team_progress:#{team.id}", :team_progress_updated)

      assert render(lv) =~ "Team Unlockable!"
    end
  end
end
