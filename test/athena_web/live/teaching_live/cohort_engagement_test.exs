defmodule AthenaWeb.TeachingLive.CohortEngagementTest do
  # Not async for the same reason as the Player engagement tests: metrics
  # queries and the live PubSub roundtrip involve `Athena.Engagement`
  # processes outside the test process, which only have sandbox access when
  # the connection is shared (`async: false`).
  use AthenaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["cohorts.read", "courses.read", "engagement.read"]
      )

    teacher = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => teacher.id})

    cohort = insert(:cohort, name: "CyberSec 101", owner_id: teacher.id)
    course = insert(:course, title: "Advanced Hacking")
    section = insert(:section, course: course, title: "Network Basics")

    block =
      insert(:block,
        section: section,
        type: :text,
        order: 10,
        engagement_rule: %EngagementRule{expected_seconds: 100}
      )

    quiz_block = insert(:block, section: section, type: :quiz_question, order: 20)

    student = insert(:account)

    %{
      conn: conn,
      teacher: teacher,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    }
  end

  test "redirects when the teacher lacks engagement.read", %{cohort: cohort, course: course} do
    other_role = insert(:role, permissions: ["cohorts.read", "courses.read"])
    other_teacher = insert(:account, role: other_role)
    conn = build_conn() |> init_test_session(%{"account_id" => other_teacher.id})

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")
  end

  test "mounts and renders the course tree and default section", %{
    conn: conn,
    cohort: cohort,
    course: course,
    section: section
  } do
    {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")

    assert html =~ "CyberSec 101"
    assert html =~ "Advanced Hacking"
    assert html =~ section.title
  end

  test "shows recorded metrics for the section's block once an event has been written", %{
    conn: conn,
    cohort: cohort,
    course: course,
    section: section,
    block: block,
    student: student
  } do
    session_id = Ecto.UUID.generate()
    now = ~U[2026-01-05 12:00:00Z]

    Engagement.record_events(student.id, cohort.id, session_id, [
      %{
        block_id: block.id,
        section_id: section.id,
        event_type: :viewport_enter,
        occurred_at: now
      },
      %{
        block_id: block.id,
        section_id: section.id,
        event_type: :viewport_exit,
        occurred_at: DateTime.add(now, 42, :second)
      }
    ])

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
      )

    assert html =~ ~r/sample size[\s\S]{0,80}?>\s*1\s*</
  end

  test "drills into a single block's metrics and shows the whole-cohort filter by default", %{
    conn: conn,
    cohort: cohort,
    course: course,
    section: section,
    block: block
  } do
    {:ok, _lv, html} =
      live(
        conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
      )

    assert html =~ "Back to Section"
    assert html =~ "Whole cohort"
  end

  test "lists cohort members in the student filter dropdown", %{
    conn: conn,
    cohort: cohort,
    course: course,
    student: student
  } do
    insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

    {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")

    assert html =~ student.login
  end

  test "live-refreshes the open block's metrics (debounced) when a new event arrives", %{
    conn: conn,
    cohort: cohort,
    course: course,
    section: section,
    block: block,
    student: student
  } do
    {:ok, lv, html} =
      live(
        conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
      )

    assert html =~ ~r/sample size[\s\S]{0,80}?>\s*0\s*</

    session_id = Ecto.UUID.generate()
    now = ~U[2026-01-05 12:00:00Z]

    Engagement.record_events(student.id, cohort.id, session_id, [
      %{
        block_id: block.id,
        section_id: section.id,
        event_type: :viewport_enter,
        occurred_at: now
      },
      %{
        block_id: block.id,
        section_id: section.id,
        event_type: :viewport_exit,
        occurred_at: DateTime.add(now, 15, :second)
      }
    ])

    # The debounce timer is a real `Process.send_after/3` - drive it directly
    # instead of sleeping for the full debounce window.
    send(lv.pid, :refresh_metrics)

    assert render(lv) =~ ~r/sample size[\s\S]{0,80}?>\s*1\s*</
  end

  describe "?view=students (\"Student Radar\")" do
    test "defaults to the content view when no ?view param is given", %{
      conn: conn,
      cohort: cohort,
      course: course
    } do
      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")

      assert html =~ "Course Radar"
      refute html =~ "Slacking index"
    end

    test "renders one row per cohort member with their radar numbers", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Two independent slacking flags on two different blocks - fast_dwell
      # (5s against a 100s expectation) and heavy_paste (95% pasted) - so
      # slacking_index reaches the red threshold (>= 2).
      record_fast_dwell(student, cohort, block, section, now)
      record_heavy_paste(student, cohort, quiz_block, section, now)

      {:ok, _lv, html} =
        live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students")

      assert html =~ "Group Radar"
      assert html =~ student.login
      assert html =~ "badge-error"
      assert html =~ "Needs attention"
    end

    test "the period picker changes which window of behavior is counted", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      old_at =
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-10 * 86_400, :second)

      record_fast_dwell(student, cohort, block, section, old_at)
      record_heavy_paste(student, cohort, quiz_block, section, old_at)

      {:ok, lv, html} =
        live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students")

      # Default window (7 days) misses behavior from 10 days ago.
      assert html =~ "badge-success"
      refute html =~ "badge-error"

      html =
        lv |> element("form[phx-change=change_window]") |> render_change(%{"window" => "all"})

      assert html =~ "badge-error"
    end

    test "clicking a flagged student deep-links into their first flagged block, pre-filtered", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      record_fast_dwell(student, cohort, block, section, now)
      record_heavy_paste(student, cohort, quiz_block, section, now)

      {:ok, lv, _html} =
        live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students")

      html =
        lv
        |> element("a", student.login)
        |> render_click()

      assert html =~ "Back to Section"
      # `block` (order 10) sorts before `quiz_block` (order 20), so it is
      # the first flagged block - the deep link must land there.
      assert_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}&account_id=#{student.id}"
      )
    end

    test "a student with no flagged behavior shows green and links to the whole-cohort view", %{
      conn: conn,
      cohort: cohort,
      course: course,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      {:ok, lv, html} =
        live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students")

      assert html =~ "badge-success"

      html = lv |> element("a", student.login) |> render_click()
      assert html =~ "Course Radar"
    end

    test "the scatter chart plots one point per student, matching the table's numbers", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_fast_dwell(student, cohort, block, section, now)
      record_heavy_paste(student, cohort, quiz_block, section, now)

      {:ok, _lv, html} =
        live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students")

      config = chart_config_from_html(html, "student-radar-scatter")

      assert config["type"] == "scatter"

      assert [%{"x" => 2, "y" => 0, "label" => login}] =
               config["data"]["datasets"] |> hd() |> Map.get("data")

      assert login == student.login
    end

    test "clicking a scatter point drills down into that student's first flagged block", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_fast_dwell(student, cohort, block, section, now)
      record_heavy_paste(student, cohort, quiz_block, section, now)

      {:ok, lv, _html} =
        live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students")

      render_hook(lv, "chart_point_click", %{"chart" => "student-radar-scatter", "index" => 0})

      assert_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}&account_id=#{student.id}"
      )
    end

    test "clicking an out-of-range chart index is a no-op, not a crash", %{
      conn: conn,
      cohort: cohort,
      course: course
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students")

      html =
        render_hook(lv, "chart_point_click", %{"chart" => "student-radar-scatter", "index" => 5})

      assert html =~ "Group Radar"
    end
  end

  describe "\"Course Radar\" content-flag sorting and weekly trend" do
    test "a block that most students backtrack to is badged and sorted first", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      # A third, earliest, never-visited block - so `block` (order 10) is
      # not already first in the list, and moving it to the front is a real
      # reordering, not a no-op.
      intro_block = insert(:block, section: section, type: :text, order: 5)

      # Every student in the cohort first reaches `quiz_block` (order 20,
      # later content), then returns to `block` (order 10) - "backtracking
      # to earlier content" per `backtrack_count/3`. Most of the cohort
      # doing this makes it a content problem, not a student one, so
      # `block` must be badged and sorted ahead of the other two.
      other_student = insert(:account)

      for s <- [student, other_student] do
        insert(:cohort_membership, account_id: s.id, cohort_id: cohort.id)
        session_id = Ecto.UUID.generate()
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Engagement.record_events(s.id, cohort.id, session_id, [
          %{
            block_id: quiz_block.id,
            section_id: section.id,
            event_type: :viewport_enter,
            occurred_at: now
          },
          %{
            block_id: block.id,
            section_id: section.id,
            event_type: :viewport_enter,
            occurred_at: DateTime.add(now, 5, :second)
          }
        ])
      end

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      assert html =~ "Content issue"

      flagged_pos = :binary.match(html, "Content issue") |> elem(0)
      block_pos = :binary.match(html, "block_id=#{block.id}") |> elem(0)
      intro_pos = :binary.match(html, "block_id=#{intro_block.id}") |> elem(0)

      # `block`'s card (badge included) renders before the unflagged
      # `intro_block` card despite `intro_block` having a lower `order`.
      assert block_pos < intro_pos
      assert flagged_pos < intro_pos
    end

    test "no content flags means no badge and the original block order", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      refute html =~ "Content issue"
    end

    test "the weekly trend table renders points for a selected block and reacts to the metric picker",
         %{
           conn: conn,
           cohort: cohort,
           course: course,
           section: section,
           block: block,
           student: student
         } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      session_id = Ecto.UUID.generate()

      Engagement.record_events(student.id, cohort.id, session_id, [
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_enter,
          occurred_at: now
        },
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_exit,
          occurred_at: DateTime.add(now, 42, :second)
        }
      ])

      {:ok, lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      assert html =~ "Weekly trend"
      assert html =~ Date.to_string(Date.beginning_of_week(DateTime.to_date(now)))

      html =
        lv
        |> element("form[phx-change=change_trend_metric]")
        |> render_change(%{"metric" => "sample_size"})

      assert html =~ "Weekly trend"
      assert html =~ ~r/Week[\s\S]*Value/
    end

    test "the weekly trend table shows a placeholder when there is no data yet", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      assert html =~ "No data yet."
    end
  end

  describe "\"Course Radar\" dwell distribution histogram" do
    test "shows a bucket for a recorded dwell, mentions the nudge cutoff percentile", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      student: student
    } do
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Engagement.record_events(student.id, cohort.id, session_id, [
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_enter,
          occurred_at: now
        },
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_exit,
          occurred_at: DateTime.add(now, 60, :second)
        }
      ])

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      assert html =~ "Dwell distribution"
      assert html =~ "10%"

      config = chart_config_from_html(html, "dwell-histogram")
      assert config["type"] == "bar"
      assert Enum.sum(hd(config["data"]["datasets"])["data"]) == 1
    end

    test "with no dwells at all, renders a valid empty histogram", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      config = chart_config_from_html(html, "dwell-histogram")
      assert Enum.sum(hd(config["data"]["datasets"])["data"]) == 0
    end

    test "the histogram is not rendered (default empty config) on the section/block-list view", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      refute html =~ "Dwell distribution"
    end
  end

  describe "\"Course Radar\" section flag stacked bar" do
    test "one bar per section, slacking and struggling counts summed from that section's blocks",
         %{
           conn: conn,
           cohort: cohort,
           course: course,
           section: section,
           block: block,
           quiz_block: quiz_block,
           student: student
         } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_fast_dwell(student, cohort, block, section, now)
      record_heavy_paste(student, cohort, quiz_block, section, now)

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "section-flag-stacked-bar")

      assert config["type"] == "bar"
      assert config["data"]["labels"] == [section.title]
      slacking = Enum.find(config["data"]["datasets"], &(&1["label"] == "Slacking"))
      struggling = Enum.find(config["data"]["datasets"], &(&1["label"] == "Struggling"))
      # fast_dwell on `block` + heavy_paste on `quiz_block`, both in `section`.
      assert slacking["data"] == [2]
      assert struggling["data"] == [0]
    end

    test "the period picker changes which window of behavior is counted", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      old_at =
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-10 * 86_400, :second)

      record_fast_dwell(student, cohort, block, section, old_at)

      {:ok, lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "section-flag-stacked-bar")
      slacking = Enum.find(config["data"]["datasets"], &(&1["label"] == "Slacking"))
      # Default window (7 days) misses behavior from 10 days ago.
      assert slacking["data"] == [0]

      html =
        lv
        |> element("form[phx-change=change_course_window]")
        |> render_change(%{"window" => "all"})

      config = chart_config_from_html(html, "section-flag-stacked-bar")
      slacking = Enum.find(config["data"]["datasets"], &(&1["label"] == "Slacking"))
      assert slacking["data"] == [1]
    end

    test "selecting a block skips recomputing the course-wide charts entirely, section view recomputes them again",
         %{
           conn: conn,
           cohort: cohort,
           course: course,
           section: section,
           block: block,
           quiz_block: quiz_block,
           student: student
         } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_fast_dwell(student, cohort, block, section, now)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      chart_before_block_selected =
        :sys.get_state(lv.pid).socket.assigns.section_chart_config

      # New flagged behavior that WOULD change `@section_chart_config` if
      # `refresh_course_charts/1` ran again.
      record_heavy_paste(student, cohort, quiz_block, section, now)

      render_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
      )

      chart_while_block_selected =
        :sys.get_state(lv.pid).socket.assigns.section_chart_config

      # Unchanged term - proves `refresh_course_charts/1` did not re-run
      # while the block-detail sub-view (which never renders this chart)
      # was active.
      assert chart_while_block_selected == chart_before_block_selected

      render_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
      )

      chart_back_on_section_view =
        :sys.get_state(lv.pid).socket.assigns.section_chart_config

      # Back on the section/course-radar view, the charts recompute again
      # and now reflect the heavy_paste event recorded while a block was
      # selected - confirming the skip is conditional, not a permanent
      # regression.
      assert chart_back_on_section_view != chart_before_block_selected
    end

    test "changing the course window preserves the current section", %{
      conn: conn,
      cohort: cohort,
      course: course
    } do
      other_section = insert(:section, course: course, order: 20)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{other_section.id}"
        )

      lv
      |> element("form[phx-change=change_course_window]")
      |> render_change(%{"window" => "30"})

      assert_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{other_section.id}&account_id=&course_window=30"
      )
    end
  end

  describe "\"Course Radar\" activity heatmap" do
    test "renders a bubble for the day/hour a student was actually active", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Engagement.record_events(student.id, cohort.id, Ecto.UUID.generate(), [
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_enter,
          occurred_at: now
        }
      ])

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "activity-heatmap")

      assert config["type"] == "bubble"
      assert [%{"data" => data}] = config["data"]["datasets"]
      expected_day = Date.day_of_week(DateTime.to_date(now))
      assert Enum.any?(data, &(&1["x"] == now.hour and &1["y"] == expected_day))
    end

    test "with no activity at all, renders an empty (not crashing) chart", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "activity-heatmap")

      assert config["data"]["datasets"] == [
               %{"backgroundColor" => "#3b82f6b3", "data" => [], "label" => "Activity"}
             ]
    end
  end

  describe "\"Course Radar\" course funnel" do
    test "shows opened/interacted/completed for the section, matching real activity", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      session = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Engagement.record_events(student.id, cohort.id, session, [
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_enter,
          occurred_at: now
        },
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_exit,
          occurred_at: DateTime.add(now, 5, :second)
        }
      ])

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "course-funnel-chart")

      assert config["type"] == "bar"
      assert config["data"]["labels"] == [section.title]
      opened = Enum.find(config["data"]["datasets"], &(&1["label"] == "Opened"))
      interacted = Enum.find(config["data"]["datasets"], &(&1["label"] == "Interacted"))
      completed = Enum.find(config["data"]["datasets"], &(&1["label"] == "Completed"))

      assert opened["data"] == [1]
      assert interacted["data"] == [1]
      assert completed["data"] == [0]
    end

    test "with no activity at all, renders a valid empty-course chart", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "course-funnel-chart")

      opened = Enum.find(config["data"]["datasets"], &(&1["label"] == "Opened"))
      assert opened["data"] == [0]
    end
  end

  describe "\"Course Radar\" active students trend" do
    test "plots today's active student count as a point on the line", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Engagement.record_events(student.id, cohort.id, Ecto.UUID.generate(), [
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_enter,
          occurred_at: now
        }
      ])

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "active-students-trend")

      assert config["type"] == "line"
      today = Date.to_string(DateTime.to_date(now))
      assert config["data"]["labels"] == [today]
      assert [%{"data" => [1]}] = config["data"]["datasets"]
    end

    test "with no activity at all, renders a valid empty trend chart", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "active-students-trend")

      assert config["data"]["labels"] == []
      assert [%{"data" => []}] = config["data"]["datasets"]
    end
  end

  describe "\"Course Radar\" nudge correction rate" do
    test "shows a bar for a nudge reason, humanized, with its correction rate as a percent", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      student: student
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Engagement.record_events(student.id, cohort.id, Ecto.UUID.generate(), [
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :nudge_shown,
          occurred_at: now,
          payload: %{"reason" => "fast_dwell"}
        }
      ])

      # After the nudge, a normal-speed dwell (100s against the block's
      # 100s expectation) - corrected.
      session = Ecto.UUID.generate()
      later = DateTime.add(now, 60, :second)

      Engagement.record_events(student.id, cohort.id, session, [
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_enter,
          occurred_at: later
        },
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_exit,
          occurred_at: DateTime.add(later, 100, :second)
        }
      ])

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "nudge-correction-rate-chart")

      assert config["type"] == "bar"
      assert config["data"]["labels"] == ["fast dwell"]
      assert [%{"data" => [100.0]}] = config["data"]["datasets"]
    end

    test "with no nudges at all, renders a valid empty chart", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      config = chart_config_from_html(html, "nudge-correction-rate-chart")

      assert config["data"]["labels"] == []
      assert [%{"data" => []}] = config["data"]["datasets"]
    end
  end

  defp record_fast_dwell(student, cohort, block, section, at) do
    session_id = Ecto.UUID.generate()

    Engagement.record_events(student.id, cohort.id, session_id, [
      %{block_id: block.id, section_id: section.id, event_type: :viewport_enter, occurred_at: at},
      %{
        block_id: block.id,
        section_id: section.id,
        event_type: :viewport_exit,
        occurred_at: DateTime.add(at, 5, :second)
      }
    ])
  end

  defp record_heavy_paste(student, cohort, block, section, at) do
    Engagement.record_events(student.id, cohort.id, Ecto.UUID.generate(), [
      %{
        block_id: block.id,
        section_id: section.id,
        event_type: :paste_detected,
        occurred_at: at,
        payload: %{"pasted_chars" => 95, "total_chars" => 100}
      }
    ])
  end

  defp chart_config_from_html(html, chart_id) do
    [_, raw_json] = Regex.run(~r/id="#{chart_id}"[^>]*data-config="([^"]*)"/s, html)

    raw_json
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> Jason.decode!()
  end
end
