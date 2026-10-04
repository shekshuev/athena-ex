defmodule AthenaWeb.TeachingLive.CohortGradebookTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "cohorts.read",
          "courses.read",
          "grading.read",
          "grading.update",
          "engagement.read"
        ]
      )

    teacher = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => teacher.id})

    cohort = insert(:cohort, name: "Group 3", owner_id: teacher.id)
    course = insert(:course, title: "Python")
    loops = insert(:section, course: course, title: "Loops", order: 10)
    funcs = insert(:section, course: course, title: "Functions", order: 20)

    insert(:block, section: loops, type: :text, order: 5)
    quiz = insert(:block, section: loops, type: :quiz_question, order: 10)
    code = insert(:block, section: loops, type: :code, order: 20)
    exam = insert(:block, section: funcs, type: :quiz_exam, order: 10)

    ivanov = insert(:account, login: "ivanov")
    petrova = insert(:account, login: "petrova")
    insert(:cohort_membership, account_id: ivanov.id, cohort_id: cohort.id)
    insert(:cohort_membership, account_id: petrova.id, cohort_id: cohort.id)

    %{
      conn: conn,
      teacher: teacher,
      cohort: cohort,
      course: course,
      loops: loops,
      quiz: quiz,
      code: code,
      exam: exam,
      ivanov: ivanov,
      petrova: petrova
    }
  end

  defp gb_path(ctx, query \\ "") do
    ~p"/teaching/cohorts/#{ctx.cohort.id}/gradebook/#{ctx.course.id}" <> query
  end

  defp submit(account, block, status, score, minutes_ago \\ 10) do
    at =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(-minutes_ago * 60, :second)

    insert(:submission,
      account_id: account.id,
      block_id: block.id,
      status: status,
      score: score,
      inserted_at: at,
      updated_at: at
    )
  end

  defp cell(lv, row_account, block) do
    lv |> element("#cell-#{row_account.id}-#{block.id}") |> render()
  end

  test "redirects a teacher without grading.read", ctx do
    role = insert(:role, permissions: ["cohorts.read", "courses.read"])
    other = insert(:account, role: role)
    conn = build_conn() |> init_test_session(%{"account_id" => other.id})

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, gb_path(ctx))
  end

  test "shows every student and every gradable block with their scores", ctx do
    submission = submit(ctx.ivanov, ctx.quiz, :graded, 30)
    submit(ctx.petrova, ctx.exam, :needs_review, 0)

    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))

    assert has_element?(lv, "#gradebook")
    assert has_element?(lv, "#row-#{ctx.ivanov.id}")
    assert has_element?(lv, "#row-#{ctx.petrova.id}")
    assert has_element?(lv, "#col-#{ctx.quiz.id}")
    assert has_element?(lv, "#col-#{ctx.code.id}")
    assert has_element?(lv, "#col-#{ctx.exam.id}")
    refute render(lv) =~ "Loops · 1. Text"

    assert cell(lv, ctx.ivanov, ctx.quiz) =~ "30"
    assert cell(lv, ctx.ivanov, ctx.quiz) =~ "/teaching/grading/#{submission.id}"
    assert cell(lv, ctx.petrova, ctx.exam) =~ "hero-eye-mini"
    assert cell(lv, ctx.ivanov, ctx.code) =~ "–"
  end

  test "the student picker narrows the rows and is kept in the URL", ctx do
    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))

    lv
    |> element("#gradebook-filters")
    |> render_change(%{"students" => ["", ctx.ivanov.id]})

    assert_patch(lv, gb_path(ctx, "?students=#{ctx.ivanov.id}"))
    assert has_element?(lv, "#row-#{ctx.ivanov.id}")
    refute has_element?(lv, "#row-#{ctx.petrova.id}")

    render_click(lv, "select_all_students")
    assert_patch(lv, gb_path(ctx))
    assert has_element?(lv, "#row-#{ctx.petrova.id}")
  end

  test "the block picker: clearing everything shows the no-results state, sections toggle",
       ctx do
    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))

    render_click(lv, "clear_blocks")
    assert has_element?(lv, "#gradebook-no-results")

    render_click(lv, "toggle_section", %{"section_id" => ctx.loops.id})
    assert has_element?(lv, "#col-#{ctx.quiz.id}")
    assert has_element?(lv, "#col-#{ctx.code.id}")
    refute has_element?(lv, "#col-#{ctx.exam.id}")
  end

  test "task type chips filter columns", ctx do
    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))

    lv |> element("#gradebook-filters") |> render_change(%{"types" => ["", "quiz_exam"]})

    assert_patch(lv, gb_path(ctx, "?types=quiz_exam"))
    assert has_element?(lv, "#col-#{ctx.exam.id}")
    refute has_element?(lv, "#col-#{ctx.quiz.id}")
  end

  test "the review tile toggles the review filter without dropping other filters", ctx do
    submit(ctx.petrova, ctx.exam, :needs_review, 0)

    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx, "?types=quiz_exam"))

    lv |> element("#gradebook-review-tile") |> render_click()
    assert_patch(lv, gb_path(ctx, "?status=review&types=quiz_exam"))
    assert has_element?(lv, "#row-#{ctx.petrova.id}")
    refute has_element?(lv, "#row-#{ctx.ivanov.id}")

    lv |> element("#gradebook-review-tile") |> render_click()
    assert_patch(lv, gb_path(ctx, "?types=quiz_exam"))
  end

  test "status filter keeps only matching students, compact hides empty tasks", ctx do
    submit(ctx.ivanov, ctx.quiz, :graded, 30)
    submit(ctx.petrova, ctx.quiz, :graded, 90)

    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx, "?status=failed"))

    assert has_element?(lv, "#row-#{ctx.ivanov.id}")
    refute has_element?(lv, "#row-#{ctx.petrova.id}")
    assert has_element?(lv, "#col-#{ctx.code.id}")

    lv |> element("#gradebook-filters") |> render_change(%{"compact" => "1"})

    assert has_element?(lv, "#col-#{ctx.quiz.id}")
    refute has_element?(lv, "#col-#{ctx.code.id}")
  end

  test "attempt policy, pass mark and pass/fail view", ctx do
    submit(ctx.ivanov, ctx.quiz, :graded, 90, 30)
    submit(ctx.ivanov, ctx.quiz, :graded, 55, 10)

    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))
    assert cell(lv, ctx.ivanov, ctx.quiz) =~ "90"
    assert cell(lv, ctx.ivanov, ctx.quiz) =~ "×2"

    lv |> element("#gradebook-filters") |> render_change(%{"attempt" => "last"})
    assert cell(lv, ctx.ivanov, ctx.quiz) =~ "55"

    lv
    |> element("#gradebook-filters")
    |> render_change(%{"display" => "pass", "threshold" => "60"})

    assert_patch(lv, gb_path(ctx, "?attempt=last&display=pass&threshold=60"))
    assert cell(lv, ctx.ivanov, ctx.quiz) =~ "hero-x-mark-mini"
  end

  test "the date range only counts attempts submitted inside it", ctx do
    submit(ctx.ivanov, ctx.quiz, :graded, 100, 5 * 24 * 60)

    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))
    assert cell(lv, ctx.ivanov, ctx.quiz) =~ "100"

    from = Athena.TimeZones.today() |> Date.add(-1) |> Date.to_iso8601()
    lv |> element("#gradebook-filters") |> render_change(%{"from" => from})

    assert cell(lv, ctx.ivanov, ctx.quiz) =~ "–"
  end

  test "sorting by a task puts the best score first", ctx do
    submit(ctx.ivanov, ctx.quiz, :graded, 30)
    submit(ctx.petrova, ctx.quiz, :graded, 90)

    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))
    render_click(lv, "sort", %{"key" => "block:#{ctx.quiz.id}"})

    row_ids =
      lv
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("tbody tr")
      |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))

    assert row_ids == ["row-#{ctx.petrova.id}", "row-#{ctx.ivanov.id}"]
  end

  test "a section collapses into one average column and the reset button clears filters",
       ctx do
    submit(ctx.ivanov, ctx.quiz, :graded, 40)
    submit(ctx.ivanov, ctx.code, :accepted, 100)

    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx, "?status=failed"))
    assert has_element?(lv, "#gradebook-reset")

    render_click(lv, "toggle_collapse", %{"section_id" => ctx.loops.id})

    refute has_element?(lv, "#col-#{ctx.quiz.id}")
    assert render(lv) =~ "Loops: average 70, passed 1 of 2"

    lv |> element("#gradebook-reset") |> render_click()
    assert_patch(lv, gb_path(ctx))
    assert has_element?(lv, "#col-#{ctx.quiz.id}")
    refute has_element?(lv, "#gradebook-reset")
  end

  test "analytics tabs link the gradebook and the engagement radars both ways", ctx do
    {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))
    assert has_element?(lv, "#group-radar-tab")
    assert has_element?(lv, "#course-radar-tab")

    {:ok, lv, _html} =
      live(ctx.conn, ~p"/teaching/cohorts/#{ctx.cohort.id}/engagement/#{ctx.course.id}")

    render_async(lv)
    assert has_element?(lv, "#gradebook-tab[href='#{gb_path(ctx)}']")
  end

  describe "CSV export" do
    test "downloads the filtered gradebook", ctx do
      submit(ctx.ivanov, ctx.quiz, :graded, 30)
      submit(ctx.petrova, ctx.quiz, :graded, 90)

      conn =
        get(
          ctx.conn,
          ~p"/teaching/cohorts/#{ctx.cohort.id}/gradebook/#{ctx.course.id}/export.csv?status=failed"
        )

      body = response(conn, 200)
      assert ["﻿" <> header, row] = String.split(body, "\r\n")
      assert header =~ "Loops · 1. Question"
      assert row =~ "ivanov"
      assert row =~ "30"
      refute body =~ "petrova"
    end

    test "is forbidden for a cohort the teacher cannot see", ctx do
      role =
        insert(:role, permissions: ["grading.read"], policies: %{"cohorts.read" => ["own_only"]})

      other = insert(:account, role: role)
      conn = build_conn() |> init_test_session(%{"account_id" => other.id})

      conn =
        get(conn, ~p"/teaching/cohorts/#{ctx.cohort.id}/gradebook/#{ctx.course.id}/export.csv")

      assert response(conn, 403)
    end
  end

  describe "scores + engagement layer" do
    setup ctx do
      text = Athena.Repo.get_by!(Athena.Content.Block, section_id: ctx.loops.id, type: :text)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Ivanov was on the quiz (so active) but never opened the text in front of it.
      Athena.Engagement.record_events(ctx.ivanov.id, ctx.cohort.id, Ecto.UUID.generate(), [
        %{
          block_id: ctx.quiz.id,
          section_id: ctx.loops.id,
          event_type: :viewport_enter,
          occurred_at: now
        }
      ])

      submit(ctx.ivanov, ctx.quiz, :graded, 30)
      %{text: text}
    end

    defp engagement(ctx, query \\ "") do
      {:ok, lv, _html} = live(ctx.conn, gb_path(ctx, "?layer=engagement" <> query))
      render_async(lv)
      lv
    end

    test "switching modes keeps it in the URL and marks skipped theory", ctx do
      {:ok, lv, _html} = live(ctx.conn, gb_path(ctx))
      assert has_element?(lv, "#mode-scores[aria-pressed=true]")

      lv |> element("#mode-engagement") |> render_click()
      assert_patch(lv, gb_path(ctx, "?layer=engagement"))
      render_async(lv)

      assert has_element?(lv, "#cell-#{ctx.ivanov.id}-#{ctx.quiz.id} [data-marker=theory]")
      refute has_element?(lv, "#cell-#{ctx.ivanov.id}-#{ctx.code.id} [data-marker]")
      assert has_element?(lv, "#layer-legend")

      lv |> element("#mode-scores") |> render_click()
      assert_patch(lv, gb_path(ctx))
      refute has_element?(lv, "[data-marker]")
    end

    test "clicking a cell explains it against the theory in front of it", ctx do
      lv = engagement(ctx)

      lv |> element("#cell-#{ctx.ivanov.id}-#{ctx.quiz.id}") |> render_click()

      assert has_element?(lv, "#cell-inspector")
      theory = lv |> element("#inspector-theory") |> render()
      assert theory =~ "Loops · 1. Text"
      assert theory =~ "never opened"
      assert lv |> element("#inspector-verdict") |> render() =~ "Most likely the topic"
      assert has_element?(lv, "#inspector-open-answer")

      render_click(lv, "close_inspect")
      refute has_element?(lv, "#cell-inspector")
    end

    test "theory columns show how every student went through the content", ctx do
      lv = engagement(ctx)
      refute has_element?(lv, "#theory-col-#{ctx.text.id}")

      lv |> element("#toggle-theory") |> render_click()
      assert_patch(lv, gb_path(ctx, "?layer=engagement&theory=1"))

      assert has_element?(lv, "#theory-col-#{ctx.text.id}")

      assert lv |> element("#theory-#{ctx.ivanov.id}-#{ctx.text.id}") |> render() =~
               "hero-minus-mini"
    end

    test "rows can be filtered by Group Radar status", ctx do
      lv = engagement(ctx)

      lv |> element("#gradebook-filters") |> render_change(%{"level" => "inactive"})
      assert_patch(lv, gb_path(ctx, "?layer=engagement&level=inactive"))

      assert has_element?(lv, "#row-#{ctx.petrova.id}")
      refute has_element?(lv, "#row-#{ctx.ivanov.id}")

      # One failed task alone doesn't make "not mastering" - Ivanov is fine.
      lv |> element("#gradebook-filters") |> render_change(%{"level" => "on_track"})
      assert has_element?(lv, "#row-#{ctx.ivanov.id}")
      refute has_element?(lv, "#row-#{ctx.petrova.id}")
    end

    test "an exam attempt flagged by the cheating monitor is marked", ctx do
      insert(:submission,
        account_id: ctx.petrova.id,
        block_id: ctx.exam.id,
        status: :graded,
        score: 90,
        content: %{"risk_level" => "red"}
      )

      lv = engagement(ctx)
      assert has_element?(lv, "#cell-#{ctx.petrova.id}-#{ctx.exam.id} [data-marker=integrity]")

      lv |> element("#cell-#{ctx.petrova.id}-#{ctx.exam.id}") |> render_click()
      assert has_element?(lv, "#inspector-integrity")
    end

    test "without engagement.read there is no layer, whatever the URL says", ctx do
      role = insert(:role, permissions: ["cohorts.read", "courses.read", "grading.read"])
      teacher = insert(:account, role: role)
      Athena.Repo.update!(Ecto.Changeset.change(ctx.cohort, owner_id: teacher.id))
      conn = build_conn() |> init_test_session(%{"account_id" => teacher.id})

      {:ok, lv, _html} = live(conn, gb_path(ctx, "?layer=engagement"))
      refute has_element?(lv, "#gradebook-mode")
      refute has_element?(lv, "[data-marker]")
    end
  end
end
