defmodule AthenaWeb.LearnLive.PlayerTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  import Ecto.Query
  alias Athena.Content.{CompletionRule, AccessRules}

  setup %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})

    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)

    if :global.whereis_name(:code_runner) == :undefined do
      :global.register_name(:code_runner, self())
    end

    on_exit(fn ->
      if :global.whereis_name(:code_runner) == self() do
        :global.unregister_name(:code_runner)
      end
    end)

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
        content: %{"language" => "python", "initial_code" => "print(1)"}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Simple paragraph"
      assert html =~ ~s(src="http://s3.com/img.jpg")
      assert html =~ ~s(alt="A test image")
      assert html =~ ~s(src="http://s3.com/vid.mp4")
      assert html =~ ~s(poster="http://s3.com/poster.jpg")
      assert html =~ "doc.pdf"
      assert html =~ "print(1)"
      assert html =~ "python"
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

    test "renders blocks after an uncompleted gate if a subsequent block has reset_waterline: true",
         %{conn: conn, course: course} do
      s1 = insert(:section, course: course)
      insert(:block, section: s1, order: 10, content: %{"text" => "Block 1"})

      insert(:block, section: s1, order: 20, completion_rule: %CompletionRule{type: :button})

      insert(:block,
        section: s1,
        order: 30,
        access_rules: %AccessRules{reset_waterline: true},
        content: %{"text" => "Rebel Block 3"}
      )

      insert(:block, section: s1, order: 40, content: %{"text" => "Block 4"})

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Block 1"
      assert html =~ "Rebel Block 3"
      assert html =~ "Block 4"
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

      insert(:block,
        section: nil,
        section_id: s1.id,
        completion_rule: %CompletionRule{type: :button}
      )

      s2 = insert(:section, course: course, order: 2)
      insert(:block, section: nil, section_id: s2.id)

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

      insert(:block,
        section: nil,
        section_id: s1.id,
        order: 10,
        content: %{"text" => "Normal Block"}
      )

      insert(:block,
        section: nil,
        section_id: s1.id,
        order: 20,
        visibility: :restricted,
        access_rules: %AccessRules{unlock_at: future},
        content: %{"text" => "Future Block"}
      )

      insert(:block,
        section: nil,
        section_id: s1.id,
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

      insert(:block, section: nil, section_id: s1.id)

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      admin = insert(:account, role: insert(:role, permissions: ["courses.update"]))

      Athena.Content.update_section(admin, s1, %{"visibility" => "hidden"})

      Process.sleep(150)

      assert_redirect(lv, "/learn/courses/#{course.id}")
    end

    test "relocks content dynamically when a submission is deleted and progress is rolled back",
         %{
           conn: conn,
           course: course,
           user: user
         } do
      s1 = insert(:section, course: course)

      gate_block =
        insert(:block, section: s1, order: 10, completion_rule: %CompletionRule{type: :button})

      insert(:block, section: s1, order: 20, content: %{"text" => "You passed the gate!"})

      Athena.Learning.mark_completed(user.id, gate_block.id)

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")
      assert html =~ "You passed the gate!"
      refute html =~ "Continue"

      Athena.Learning.Progress.revoke_completed(Athena.Repo, user.id, gate_block.id)

      send(lv.pid, :user_progress_updated)

      html_after = render(lv)

      refute html_after =~ "You passed the gate!"
      assert html_after =~ "Continue"
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

      refute html =~ "Hidden in plain sight."

      html =
        lv
        |> form("#quiz-form-#{block.id}", %{"answer" => "flag{123}"})
        |> render_submit()

      assert html =~ "Hidden in plain sight."
      assert html =~ "Locked"
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

      assert html =~ "Retry Answer"
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

      assert html =~ "Locked"
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

      assert html =~ "Locked"
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

      assert html =~ "Retry Answer"
      assert html =~ "Secret Content"
    end

    test "renders instructor feedback when provided", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :graded,
        score: 80,
        feedback: "Good essay, but you missed a few commas."
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Instructor Feedback"
      assert html =~ "Good essay, but you missed a few commas."
      refute html =~ "Submit Answer"
    end

    test "renders rejected status, shows feedback, and locks the form", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :rejected,
        score: 0,
        feedback: "Copied from ChatGPT. Disqualified."
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Instructor Feedback"
      assert html =~ "Copied from ChatGPT. Disqualified."
      assert html =~ "Locked"
      refute html =~ "Submit Answer"
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

      assert html =~ "Assessment Session"
      assert html =~ "15 Questions"
      assert html =~ "45 Min"
      assert html =~ "Start Assessment"

      lv |> element("button[phx-click='start_exam']") |> render_click()
      assert_redirect(lv, "/learn/courses/#{course.id}/exam/#{block.id}")

      sub = Athena.Repo.one(Athena.Learning.Submission)
      assert sub.status == :pending
      assert sub.block_id == block.id
      assert sub.content["type"] == "quiz_exam" or sub.content["type"] == :quiz_exam
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

      assert html =~ "Continue Assessment"
      refute html =~ "Start Assessment"

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

      assert html =~ "Assessment Completed"
      assert html =~ "85 / 100"
      refute html =~ "Start Assessment"
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

      assert html =~ "Assessment Failed (Violations)"
      refute html =~ "Assessment Completed"
      refute html =~ "Start Assessment"
    end
  end

  describe "Ticket Exam Block" do
    test "renders initial ticket card and starts exam, redirecting to ticket route", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block,
          section: s1,
          type: :ticket_exam,
          content: %{
            "slots" => [%{"id" => "1", "tags" => []}, %{"id" => "2", "tags" => []}],
            "time_limit" => 45
          }
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Ticket Assessment"

      assert html =~ "2 Questions"
      assert html =~ "45 Min"
      assert html =~ "Start Assessment"

      lv |> element("button[phx-click='start_exam']") |> render_click()

      assert_redirect(lv, "/learn/courses/#{course.id}/ticket/#{block.id}")

      sub = Athena.Repo.one(Athena.Learning.Submission)
      assert sub.status == :pending
      assert sub.block_id == block.id
      assert sub.content["type"] == "ticket_exam"
    end

    test "renders continue button if ticket is pending and redirects to ticket route", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :ticket_exam, content: %{"slots" => [%{"id" => "1"}]})

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        content: %{
          "type" => "ticket_exam",
          "cheat_count" => 0,
          "started_at" => DateTime.utc_now()
        }
      )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Continue Assessment"
      refute html =~ "Start Assessment"

      lv |> element("button[phx-click='continue_exam']") |> render_click()

      assert_redirect(lv, "/learn/courses/#{course.id}/ticket/#{block.id}")
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

      insert(:enrollment, course_id: course.id, cohort_id: cohort.id)

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

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Secret Override Content"
    end

    test "cohort override locks a globally unlocked block", %{
      conn: conn,
      course: course,
      user: user
    } do
      cohort = insert(:cohort)
      insert(:cohort_membership, account_id: user.id, cohort_id: cohort.id)
      insert(:enrollment, course_id: course.id, cohort_id: cohort.id)

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

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

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

      insert(:enrollment, course_id: course.id, cohort_id: cohort1.id)
      insert(:enrollment, course_id: course.id, cohort_id: cohort2.id)

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

      Athena.Repo.delete_all(Athena.Learning.CohortMembership,
        account_id: user.id,
        cohort_id: cohort1.id
      )

      {:ok, _lv, html_c2} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")
      assert html_c2 =~ "Visible Content"
    end
  end

  describe "Submission Context (Individual vs Team)" do
    test "individual submission sets cohort_id to nil", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "Individual work"})
      |> render_submit()

      sub = Athena.Repo.one!(Athena.Learning.Submission)
      assert sub.account_id == user.id
      assert sub.cohort_id == nil
    end

    test "team submission correctly assigns cohort_id from backend state", %{
      conn: conn,
      user: user
    } do
      course = insert(:course, type: :competition)
      team = insert(:cohort, type: :team)

      insert(:enrollment, course_id: course.id, cohort_id: team.id)
      insert(:cohort_membership, account_id: user.id, cohort_id: team.id)

      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "Team work"})
      |> render_submit()

      sub = Athena.Repo.one!(Athena.Learning.Submission)
      assert sub.account_id == user.id
      assert sub.cohort_id == team.id
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

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      refute html =~ "Team Unlockable!"

      Athena.Learning.mark_completed(teammate.id, gate.id, team.id)
      Phoenix.PubSub.broadcast(Athena.PubSub, "team_progress:#{team.id}", :team_progress_updated)

      assert render(lv) =~ "Team Unlockable!"
    end
  end

  describe "Code Submissions & Real-time Results" do
    test "submits code and reacts to async result via PubSub", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :code, content: %{"language" => "python3"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#code-form-#{block.id}")
      |> render_submit(%{
        "block_id" => block.id,
        "answer" => %{"code" => "print(1)"}
      })

      assert render(lv) =~ "Checking..."

      submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :accepted,
          score: 100,
          content: %{
            "execution_results" => [
              %{"status" => "accepted", "time" => 0.1, "is_hidden" => false}
            ]
          }
        )

      send(lv.pid, {:submission_updated, submission})

      html = render(lv)
      assert html =~ "ACCEPTED"
      refute html =~ "Checking..."
    end

    test "respects hidden test cases and masks their details", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :code)

      feedback = [
        %{
          "status" => "wrong_answer",
          "input" => "SECRET_INPUT",
          "expected" => "SECRET_OUT",
          "stdout" => "ERR",
          "is_hidden" => true,
          "time" => 0.1
        },
        %{
          "status" => "wrong_answer",
          "input" => "PUBLIC_IN",
          "expected" => "PUBLIC_OUT",
          "stdout" => "WRONG",
          "is_hidden" => false,
          "time" => 0.1
        }
      ]

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :wrong_answer,
        content: %{"execution_results" => feedback}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Hidden Test"
      refute html =~ "SECRET_INPUT"
      refute html =~ "SECRET_OUT"

      assert html =~ "PUBLIC_IN"
      assert html =~ "PUBLIC_OUT"
      assert html =~ "GOT:"
    end

    test "code gate: unlocks next block only after successful execution", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      gate_block =
        insert(:block,
          section: s1,
          type: :code,
          order: 10,
          completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 100}
        )

      insert(:block, section: s1, order: 20, content: %{"text" => "Waterfall Content"})

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      refute html =~ "Waterfall Content"

      bad_sub =
        insert(:submission,
          account_id: user.id,
          block_id: gate_block.id,
          status: :wrong_answer,
          score: 0
        )

      send(lv.pid, {:submission_updated, bad_sub})

      refute render(lv) =~ "Waterfall Content"

      good_sub =
        insert(:submission,
          account_id: user.id,
          block_id: gate_block.id,
          status: :accepted,
          score: 100
        )

      send(lv.pid, {:submission_updated, good_sub})

      assert render(lv) =~ "Waterfall Content"
    end
  end

  describe "Max Attempts Constraints - Code Blocks" do
    test "code block displays attempts and changes button to 'Locked' when attempts are exhausted",
         %{
           conn: conn,
           course: course
         } do
      s1 = insert(:section, course: course)

      block =
        insert(:block,
          section: s1,
          type: :code,
          content: %{"language" => "python3", "max_attempts" => 1, "test_cases" => []}
        )

      {:ok, lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")
      assert html =~ "Attempts: 0 / 1"
      assert html =~ "Submit"

      lv
      |> form("#code-form-#{block.id}")
      |> render_submit(%{"block_id" => block.id, "answer" => %{"code" => "print(1)"}})

      submission = Athena.Repo.one!(Athena.Learning.Submission)

      {:ok, failed_sub} =
        Athena.Learning.system_update_submission(submission, %{
          "status" => :wrong_answer,
          "score" => 0
        })

      send(lv.pid, {:submission_updated, failed_sub})
      html = render(lv)

      assert html =~ "Attempts: 1 / 1"
      refute html =~ "Submit"
    end

    test "code block remains active if student has attempts left", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block,
          section: s1,
          type: :code,
          content: %{"language" => "python3", "max_attempts" => 3, "test_cases" => []}
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#code-form-#{block.id}")
      |> render_submit(%{"block_id" => block.id, "answer" => %{"code" => "print(1)"}})

      submission = Athena.Repo.one!(Athena.Learning.Submission)

      {:ok, failed_sub} =
        Athena.Learning.system_update_submission(submission, %{
          "status" => "wrong_answer",
          "score" => 0
        })

      send(lv.pid, {:submission_updated, failed_sub})
      html = render(lv)

      assert html =~ "Attempts: 1 / 3"
      assert html =~ "Resubmit"
      refute html =~ "Locked"
    end

    test "code block locks instantly upon accepted solution regardless of remaining attempts", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block,
          section: s1,
          type: :code,
          content: %{"language" => "python3", "max_attempts" => 5, "test_cases" => []}
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#code-form-#{block.id}")
      |> render_submit(%{"block_id" => block.id, "answer" => %{"code" => "print(1)"}})

      submission = Athena.Repo.one!(Athena.Learning.Submission)

      {:ok, success_sub} =
        Athena.Learning.system_update_submission(submission, %{
          "status" => "accepted",
          "score" => 100
        })

      send(lv.pid, {:submission_updated, success_sub})
      html = render(lv)

      assert html =~ "Attempts: 1 / 5"
    end
  end

  describe "File Assignment Submissions" do
    test "opens media upload modal when requested for file assignment", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :file_assignment, content: %{"max_files" => 3})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      render_hook(lv, "request_media_upload", %{
        "block_id" => block.id,
        "media_type" => "file_assignment"
      })

      html = render(lv)
      assert html =~ "Upload Media"
      assert html =~ "Click or drag files here"
    end

    test "cancels media upload and closes modal", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :file_assignment, content: %{"max_files" => 1})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      render_hook(lv, "request_media_upload", %{
        "block_id" => block.id,
        "media_type" => "file_assignment"
      })

      assert render(lv) =~ "Upload Media"

      lv
      |> element("button[phx-click='cancel_media_upload']")
      |> render_click()

      refute render(lv) =~ "Upload Media"
    end

    test "submits file assignment successfully after uploading files", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :file_assignment, content: %{"max_files" => 2})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      render_hook(lv, "media_upload_clipboard_success", %{
        "block_id" => block.id,
        "final_url" => "https://s3.aws/file1.pdf"
      })

      render_hook(lv, "media_upload_clipboard_success", %{
        "block_id" => block.id,
        "final_url" => "https://s3.aws/file2.pdf"
      })

      html =
        lv
        |> form("#file-assignment-form-#{block.id}")
        |> render_submit()

      assert html =~ "Assignment submitted!"

      sub =
        Athena.Repo.get_by(Athena.Learning.Submission, block_id: block.id, account_id: user.id)

      assert sub.status == :pending
      assert sub.content["type"] == "file_assignment"

      assert sub.content["file_urls"] == [
               "https://s3.aws/file1.pdf",
               "https://s3.aws/file2.pdf"
             ]
    end

    test "shows error when submitting file assignment without files", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :file_assignment, content: %{"max_files" => 2})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      html =
        lv
        |> form("#file-assignment-form-#{block.id}")
        |> render_submit()

      assert html =~ "Please upload at least one file"
    end

    test "rejects file upload when max_files limit is reached", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :file_assignment, content: %{"max_files" => 1})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      render_hook(lv, "media_upload_clipboard_success", %{
        "block_id" => block.id,
        "final_url" => "https://s3.aws/file1.pdf"
      })

      html =
        render_hook(lv, "media_upload_clipboard_success", %{
          "block_id" => block.id,
          "final_url" => "https://s3.aws/file2.pdf"
        })

      assert html =~ "Maximum number of files reached"
    end

    test "removes pending file from upload list", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :file_assignment, content: %{"max_files" => 2})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      render_hook(lv, "media_upload_clipboard_success", %{
        "block_id" => block.id,
        "final_url" => "https://s3.aws/file1.pdf"
      })

      render_hook(lv, "remove_pending_file", %{
        "block_id" => block.id,
        "url" => "https://s3.aws/file1.pdf"
      })

      html =
        lv
        |> form("#file-assignment-form-#{block.id}")
        |> render_submit()

      assert html =~ "Please upload at least one file"
    end

    test "handles saved files from MediaUploadComponent and adds to pending list", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :file_assignment, content: %{"max_files" => 2})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      render_hook(lv, "request_media_upload", %{
        "block_id" => block.id,
        "media_type" => "file_assignment"
      })

      send(lv.pid, {
        AthenaWeb.StudioLive.MediaUploadComponent,
        {:saved, block.id, "file_assignment", [{:ok, %{"url" => "https://s3.aws/saved.pdf"}}]}
      })

      html = render(lv)
      assert html =~ "File(s) ready to submit"

      lv
      |> form("#file-assignment-form-#{block.id}")
      |> render_submit()

      sub = Athena.Repo.get_by(Athena.Learning.Submission, block_id: block.id)
      assert sub.content["file_urls"] == ["https://s3.aws/saved.pdf"]
    end
  end

  describe "Draft Submissions" do
    test "loads draft from database when mounting player", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :draft,
        content: %{"type" => :quiz_question, "text_answer" => "My saved draft"}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "My saved draft"
    end

    test "loads draft from Cachex when available (faster than DB)", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      Athena.Learning.DraftCache.save_draft(
        user.id,
        nil,
        block.id,
        %{"type" => :quiz_question, "text_answer" => "Cached draft"}
      )

      {:ok, _lv, html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      assert html =~ "Cached draft"
    end

    test "saves draft when student types in textarea", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "Typing my answer..."})
      |> render_change()

      draft =
        Athena.Repo.get_by(Athena.Learning.Submission,
          block_id: block.id,
          status: :draft
        )

      assert draft != nil
      assert draft.content["text_answer"] == "Typing my answer..."
    end

    test "saves draft for code block when student types", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)
      block = insert(:block, section: s1, type: :code, content: %{"language" => "python3"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> element("#code-form-#{block.id}")
      |> render_change(%{"answer" => %{"code" => "print('draft code')"}})

      draft =
        Athena.Repo.get_by(Athena.Learning.Submission,
          block_id: block.id,
          status: :draft
        )

      assert draft != nil
      assert draft.content["code"] == "print('draft code')"
    end

    test "updates existing draft instead of creating multiple drafts", %{
      conn: conn,
      course: course
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "First version"})
      |> render_change()

      lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "Second version"})
      |> render_change()

      drafts =
        Athena.Repo.all(
          from s in Athena.Learning.Submission,
            where: s.block_id == ^block.id and s.status == :draft
        )

      assert length(drafts) == 1
      assert hd(drafts).content["text_answer"] == "Second version"
    end

    test "clears draft from cache after final submission", %{
      conn: conn,
      course: course,
      user: user
    } do
      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      {:ok, _} =
        Athena.Learning.save_draft(user, block.id, %{
          "type" => :quiz_question,
          "text_answer" => "Draft answer"
        })

      assert Athena.Learning.DraftCache.get_draft(user.id, nil, block.id) != nil

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "Final answer"})
      |> render_submit()

      assert Athena.Learning.DraftCache.get_draft(user.id, nil, block.id) == nil

      submission =
        Athena.Repo.get_by(Athena.Learning.Submission,
          block_id: block.id,
          account_id: user.id
        )

      assert submission.status != :draft
    end

    test "team draft is shared across team members via PubSub", %{conn: conn, user: user} do
      course = insert(:course, type: :competition)
      team = insert(:cohort, type: :team)

      insert(:enrollment, course_id: course.id, cohort_id: team.id)
      insert(:cohort_membership, account_id: user.id, cohort_id: team.id)

      teammate = insert(:account)
      insert(:cohort_membership, account_id: teammate.id, cohort_id: team.id)

      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      Athena.Learning.save_draft(
        teammate,
        block.id,
        %{
          "type" => :quiz_question,
          "text_answer" => "Teammate draft"
        },
        team.id
      )

      Phoenix.PubSub.broadcast(
        Athena.PubSub,
        "draft:#{team.id}:#{block.id}",
        {:draft_updated,
         %{
           block_id: block.id,
           content: %{"type" => :quiz_question, "text_answer" => "Teammate draft"},
           updater_id: teammate.id
         }}
      )

      Process.sleep(100)

      html = render(lv)
      assert html =~ "Teammate draft"
    end

    test "draft is not visible in grading view", %{conn: conn, course: course, user: user} do
      admin_role = insert(:role, permissions: ["grading.read"])
      admin = insert(:account, role: admin_role)
      admin_conn = init_test_session(conn, %{"account_id" => admin.id})

      s1 = insert(:section, course: course)

      block =
        insert(:block, section: s1, type: :quiz_question, content: %{"question_type" => "open"})

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :draft,
        content: %{"type" => :quiz_question, "text_answer" => "Hidden draft"}
      )

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :pending,
        content: %{"type" => :quiz_question, "text_answer" => "Visible submission"}
      )

      {:ok, _lv, html} = live(admin_conn, ~p"/teaching/grading")

      assert html =~ "Pending"
      assert html =~ user.login
      submission_rows = Regex.scan(~r/<tr id="submissions-/, html)
      assert length(submission_rows) == 1
    end

    test "saves draft for single choice quiz", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)
      opt1_id = Ecto.UUID.generate()
      opt2_id = Ecto.UUID.generate()

      block =
        insert(:block,
          section: s1,
          type: :quiz_question,
          content: %{
            "question_type" => "single",
            "options" => [
              %{"id" => opt1_id, "text" => "Option 1", "is_correct" => true},
              %{"id" => opt2_id, "text" => "Option 2", "is_correct" => false}
            ]
          }
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#quiz-form-#{block.id}", %{"answer" => opt1_id})
      |> render_change()

      draft =
        Athena.Repo.get_by(Athena.Learning.Submission,
          block_id: block.id,
          status: :draft
        )

      assert draft != nil
      assert draft.content["selected_choices"] == [opt1_id]
    end

    test "saves draft for multiple choice quiz", %{conn: conn, course: course} do
      s1 = insert(:section, course: course)
      opt1_id = Ecto.UUID.generate()
      opt2_id = Ecto.UUID.generate()

      block =
        insert(:block,
          section: s1,
          type: :quiz_question,
          content: %{
            "question_type" => "multiple",
            "options" => [
              %{"id" => opt1_id, "text" => "Option A", "is_correct" => true},
              %{"id" => opt2_id, "text" => "Option B", "is_correct" => true}
            ]
          }
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{s1.id}")

      lv
      |> form("#quiz-form-#{block.id}", %{
        "answer" => [opt1_id, opt2_id]
      })
      |> render_change()

      draft =
        Athena.Repo.get_by(Athena.Learning.Submission,
          block_id: block.id,
          status: :draft
        )

      assert draft != nil
      assert draft.content["selected_choices"] == [opt1_id, opt2_id]
    end
  end
end
