defmodule AthenaWeb.LearnLive.PlayerTeamRealtimeTest do
  @moduledoc """
  End-to-end checks of the three guarantees a competition (`:team` cohort)
  course is supposed to give a team, from two *real* player sessions - one
  per team member - instead of a hand-rolled PubSub broadcast:

    1. one member's submission is visible to the others (pass or fail);
    2. it reaches them live, including a resubmit;
    3. the shared waterline moves live for everyone.
  """
  use AthenaWeb.ConnCase, async: true
  use Oban.Testing, repo: Athena.Repo

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Content.CompletionRule
  alias Athena.Execution.{Result, TestResult}

  setup %{conn: conn} do
    alice = insert(:account)
    bob = insert(:account)

    course = insert(:course, type: :competition)
    team = insert(:cohort, type: :team)

    insert(:enrollment, course_id: course.id, cohort_id: team.id)
    insert(:cohort_membership, account_id: alice.id, cohort_id: team.id)
    insert(:cohort_membership, account_id: bob.id, cohort_id: team.id)

    %{
      alice_conn: init_test_session(conn, %{"account_id" => alice.id}),
      bob_conn: init_test_session(Phoenix.ConnTest.build_conn(), %{"account_id" => bob.id}),
      alice: alice,
      bob: bob,
      course: course,
      team: team
    }
  end

  describe "1. a teammate's submission is visible to the rest of the team" do
    test "a wrong quiz answer by Alice shows up in Bob's player", ctx do
      s1 = insert(:section, course: ctx.course)

      block =
        insert(:block,
          section: nil,
          section_id: s1.id,
          type: :quiz_question,
          content: %{"question_type" => "open", "correct_answer" => "right"}
        )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))
      {:ok, bob_lv, html} = live(ctx.bob_conn, play_path(ctx.course, s1))

      refute html =~ "definitely wrong"

      alice_lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "definitely wrong"})
      |> render_submit()

      sub = Athena.Repo.one!(Athena.Learning.Submission)
      assert sub.cohort_id == ctx.team.id
      assert sub.account_id == ctx.alice.id

      assert render(bob_lv) =~ "definitely wrong",
             "Bob does not see Alice's failed submission"
    end

    test "a correct quiz answer by Alice shows up in Bob's player", ctx do
      s1 = insert(:section, course: ctx.course)

      block =
        insert(:block,
          section: nil,
          section_id: s1.id,
          type: :quiz_question,
          content: %{"question_type" => "open", "correct_answer" => "right answer"}
        )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))
      {:ok, bob_lv, _} = live(ctx.bob_conn, play_path(ctx.course, s1))

      alice_lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "right answer"})
      |> render_submit()

      assert render(bob_lv) =~ "right answer", "Bob does not see Alice's accepted submission"
    end

    test "Bob's fresh mount loads the team's submission (not his own empty one)", ctx do
      s1 = insert(:section, course: ctx.course)

      block =
        insert(:block,
          section: nil,
          section_id: s1.id,
          type: :quiz_question,
          content: %{"question_type" => "open"}
        )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))

      alice_lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "alice was here"})
      |> render_submit()

      {:ok, _bob_lv, html} = live(ctx.bob_conn, play_path(ctx.course, s1))
      assert html =~ "alice was here"
    end

    test "a code submission graded by the execution worker reaches Bob", ctx do
      s1 = insert(:section, course: ctx.course)

      block =
        insert(:block,
          section: nil,
          section_id: s1.id,
          type: :code,
          content: %{"language" => "python3", "initial_code" => "# start here"}
        )

      # Alice submitted and is no longer on the page (she closed the tab, or
      # the runner took longer than her session) - the team is still owed
      # the result, so nothing here depends on her LiveView being alive.
      {:ok, sub} =
        Athena.Learning.create_submission(ctx.alice, %{
          "block_id" => block.id,
          "cohort_id" => ctx.team.id,
          "status" => :pending,
          "content" => %{"type" => :code, "code" => "print('alice solved it')"}
        })

      assert sub.cohort_id == ctx.team.id

      {:ok, bob_lv, bob_html} = live(ctx.bob_conn, play_path(ctx.course, s1))

      # Bob already sees the attempt itself - it is the team's row, loaded
      # on mount - so what is at stake is only the *result*.
      assert bob_html =~ "alice solved it"
      assert bob_html =~ "Checking..."

      # Exactly what the Oban worker does once the runner comes back.
      Athena.Execution.Worker.update_submission_with_result(sub, passing_result())

      bob_html = render(bob_lv)

      assert bob_html =~ "ACCEPTED",
             "Bob does not see the result of the team's code submission"

      refute bob_html =~ "Checking..."
    end
  end

  describe "2. realtime: a resubmit reaches every member" do
    test "Alice's second answer replaces the first one in Bob's player", ctx do
      s1 = insert(:section, course: ctx.course)

      block =
        insert(:block,
          section: nil,
          section_id: s1.id,
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "body" => %{"text" => "Type it"},
            "correct_answer" => "forty two"
          }
        )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))
      {:ok, bob_lv, _} = live(ctx.bob_conn, play_path(ctx.course, s1))

      alice_lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "first attempt"})
      |> render_submit()

      assert render(bob_lv) =~ "first attempt"

      alice_lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "forty two"})
      |> render_submit()

      bob_html = render(bob_lv)
      assert bob_html =~ "forty two"
      refute bob_html =~ "first attempt"
    end

    test "Alice's live typing (draft) reaches Bob without a submit", ctx do
      s1 = insert(:section, course: ctx.course)

      block =
        insert(:block,
          section: nil,
          section_id: s1.id,
          type: :quiz_question,
          content: %{"question_type" => "open"}
        )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))
      {:ok, bob_lv, _} = live(ctx.bob_conn, play_path(ctx.course, s1))

      alice_lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "typing out loud"})
      |> render_change()

      assert render(bob_lv) =~ "typing out loud"
    end
  end

  describe "3. the shared waterline opens for the whole team, live" do
    test "a gate Alice passes unlocks the next block for Bob", ctx do
      s1 = insert(:section, course: ctx.course)

      gate =
        insert(:block,
          section: nil,
          section_id: s1.id,
          order: 10,
          type: :quiz_question,
          completion_rule: %CompletionRule{type: :submit},
          content: %{"question_type" => "open"}
        )

      insert(:block,
        section: nil,
        section_id: s1.id,
        order: 20,
        content: %{"text" => "Behind the waterline"}
      )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))
      {:ok, bob_lv, html} = live(ctx.bob_conn, play_path(ctx.course, s1))

      refute html =~ "Behind the waterline"

      alice_lv
      |> form("#quiz-form-#{gate.id}", %{"answer" => "done"})
      |> render_submit()

      assert render(bob_lv) =~ "Behind the waterline",
             "the waterline did not move for Bob"
    end

    test "a gate Alice passes unlocks the next section for Bob", ctx do
      s1 = insert(:section, course: ctx.course, order: 1)

      gate =
        insert(:block,
          section: nil,
          section_id: s1.id,
          type: :quiz_question,
          completion_rule: %CompletionRule{type: :submit},
          content: %{"question_type" => "open"}
        )

      s2 = insert(:section, course: ctx.course, order: 2)
      insert(:block, section: nil, section_id: s2.id, content: %{"text" => "Next section body"})

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))

      assert {:error, {:live_redirect, _}} = live(ctx.bob_conn, play_path(ctx.course, s2))

      alice_lv
      |> form("#quiz-form-#{gate.id}", %{"answer" => "done"})
      |> render_submit()

      assert {:ok, _lv, html} = live(ctx.bob_conn, play_path(ctx.course, s2))
      assert html =~ "Next section body"
    end

    test "a code gate the worker accepts unlocks the next block for Bob", ctx do
      s1 = insert(:section, course: ctx.course)

      gate =
        insert(:block,
          section: nil,
          section_id: s1.id,
          order: 10,
          type: :code,
          completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 100},
          content: %{"language" => "python3", "initial_code" => "# start"}
        )

      insert(:block,
        section: nil,
        section_id: s1.id,
        order: 20,
        content: %{"text" => "Behind the code gate"}
      )

      # Alice is offline by the time the runner answers (see the code
      # submission test above for why that matters).
      {:ok, sub} =
        Athena.Learning.create_submission(ctx.alice, %{
          "block_id" => gate.id,
          "cohort_id" => ctx.team.id,
          "status" => :pending,
          "content" => %{"type" => :code, "code" => "print(42)"}
        })

      {:ok, bob_lv, bob_html} = live(ctx.bob_conn, play_path(ctx.course, s1))
      refute bob_html =~ "Behind the code gate"

      Athena.Execution.Worker.update_submission_with_result(sub, passing_result())

      assert render(bob_lv) =~ "Behind the code gate",
             "a code gate passed by the worker did not move the waterline for Bob"
    end

    test "with Alice's page open, her player is what relays the unlock to Bob", ctx do
      s1 = insert(:section, course: ctx.course)

      gate =
        insert(:block,
          section: nil,
          section_id: s1.id,
          order: 10,
          type: :code,
          completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 100},
          content: %{"language" => "python3", "initial_code" => "# start"}
        )

      insert(:block,
        section: nil,
        section_id: s1.id,
        order: 20,
        content: %{"text" => "Behind the code gate"}
      )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))
      {:ok, bob_lv, bob_html} = live(ctx.bob_conn, play_path(ctx.course, s1))

      refute bob_html =~ "Behind the code gate"

      alice_lv
      |> form("#code-form-#{gate.id}")
      |> render_submit(%{"block_id" => gate.id, "answer" => %{"code" => "print(42)"}})

      sub = Athena.Repo.one!(Athena.Learning.Submission)
      Athena.Execution.Worker.update_submission_with_result(sub, passing_result())

      # Let Alice's player handle the result first: its own gate completion
      # is the only thing that broadcasts to the team.
      _ = render(alice_lv)

      assert render(bob_lv) =~ "Behind the code gate"
    end

    test "an instructor's grade on the team's work unlocks the gate for Bob", ctx do
      s1 = insert(:section, course: ctx.course)

      gate =
        insert(:block,
          section: nil,
          section_id: s1.id,
          order: 10,
          type: :code,
          completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 100},
          content: %{"language" => "python3", "initial_code" => "# start"}
        )

      insert(:block,
        section: nil,
        section_id: s1.id,
        order: 20,
        content: %{"text" => "Behind the graded gate"}
      )

      {:ok, sub} =
        Athena.Learning.create_submission(ctx.alice, %{
          "block_id" => gate.id,
          "cohort_id" => ctx.team.id,
          "status" => :pending,
          "content" => %{"type" => :code, "code" => "print(1)"}
        })

      # The runner says no, so the gate stays shut for the whole team.
      {:ok, rejected} =
        Athena.Learning.system_update_submission(sub, %{status: :rejected, score: 0})

      {:ok, bob_lv, bob_html} = live(ctx.bob_conn, play_path(ctx.course, s1))
      refute bob_html =~ "Behind the graded gate"

      teacher = insert(:account, role: insert(:role, permissions: ["grading.update"]))

      {:ok, _graded} =
        Athena.Learning.update_submission(teacher, rejected, %{status: :graded, score: 100})

      assert render(bob_lv) =~ "Behind the graded gate",
             "an instructor's grade did not move the team's waterline for Bob"
    end

    test "an unreviewed open answer must not open a pass_auto_grade gate", ctx do
      s1 = insert(:section, course: ctx.course)

      gate =
        insert(:block,
          section: nil,
          section_id: s1.id,
          order: 10,
          type: :quiz_question,
          completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 100},
          content: %{"question_type" => "open", "body" => %{"text" => "Explain"}}
        )

      insert(:block,
        section: nil,
        section_id: s1.id,
        order: 20,
        content: %{"text" => "Behind the graded gate"}
      )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))

      alice_lv
      |> form("#quiz-form-#{gate.id}", %{"answer" => "my essay"})
      |> render_submit()

      assert %{status: :needs_review, score: nil} = Athena.Repo.one!(Athena.Learning.Submission)

      {:ok, _bob_lv, bob_html} = live(ctx.bob_conn, play_path(ctx.course, s1))

      refute bob_html =~ "Behind the graded gate",
             "an open answer nobody has graded yet satisfied a min_score gate"
    end

    test "the syllabus page shows the team's waterline, not the member's own", ctx do
      s1 = insert(:section, course: ctx.course, order: 1, title: "First")

      gate =
        insert(:block,
          section: nil,
          section_id: s1.id,
          completion_rule: %CompletionRule{type: :submit},
          type: :quiz_question,
          content: %{"question_type" => "open"}
        )

      s2 = insert(:section, course: ctx.course, order: 2, title: "Second")
      insert(:block, section: nil, section_id: s2.id, content: %{"text" => "body"})

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))

      alice_lv
      |> form("#quiz-form-#{gate.id}", %{"answer" => "done"})
      |> render_submit()

      # The player agrees the team is through the gate...
      assert {:ok, _lv, _html} = live(ctx.bob_conn, play_path(ctx.course, s2))

      # ...so the syllabus must not still show "Second" as locked.
      {:ok, syllabus, _html} = live(ctx.bob_conn, ~p"/learn/courses/#{ctx.course.id}")

      refute has_element?(syllabus, ".hero-lock-closed"),
             "the syllabus locks a section the team has already unlocked"
    end
  end

  describe "4. an instructor's grade and comment reach the whole team" do
    test "Bob sees the grade and comment left on Alice's work, live", ctx do
      s1 = insert(:section, course: ctx.course)

      block =
        insert(:block,
          section: nil,
          section_id: s1.id,
          type: :quiz_question,
          content: %{"question_type" => "open", "body" => %{"text" => "Explain"}}
        )

      {:ok, alice_lv, _} = live(ctx.alice_conn, play_path(ctx.course, s1))

      alice_lv
      |> form("#quiz-form-#{block.id}", %{"answer" => "our team's essay"})
      |> render_submit()

      {:ok, bob_lv, bob_html} = live(ctx.bob_conn, play_path(ctx.course, s1))
      refute bob_html =~ "Nicely argued, 80 for this"

      teacher = insert(:account, role: insert(:role, permissions: ["grading.update"]))
      sub = Athena.Repo.one!(Athena.Learning.Submission)

      {:ok, _graded} =
        Athena.Learning.update_submission(teacher, sub, %{
          status: :graded,
          score: 80,
          feedback: "Nicely argued, 80 for this"
        })

      bob_html = render(bob_lv)

      assert bob_html =~ "Nicely argued, 80 for this",
             "the instructor's comment did not reach the rest of the team"

      assert bob_html =~ "80"
    end
  end

  defp play_path(course, section), do: ~p"/learn/courses/#{course.id}/play/#{section.id}"

  defp passing_result do
    %Result{
      status: :accepted,
      score: 100,
      time: 0.1,
      memory: 1024,
      test_results: [
        %TestResult{
          status: :accepted,
          expected: "42",
          stdout: "42",
          stderr: nil,
          input: "",
          time: 0.1,
          memory: 1024,
          max_score: 100,
          is_hidden: false
        }
      ]
    }
  end
end
