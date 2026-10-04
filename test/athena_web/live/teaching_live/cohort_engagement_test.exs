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

  test "radars render a loading skeleton first, then the computed data", %{
    conn: conn,
    cohort: cohort,
    course: course,
    student: student
  } do
    insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
    radar_path = ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students"
    course_path = ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}"

    # The dead render never computes anything - it only shows the skeleton.
    assert conn |> get(radar_path) |> html_response(200) =~ "student-radar-loading"
    assert conn |> get(course_path) |> html_response(200) =~ "course-map-loading"

    {:ok, lv, _html} = live(conn, radar_path)
    render_async(lv)
    refute has_element?(lv, "#student-radar-loading")
    assert has_element?(lv, "#group-radar-table")

    {:ok, lv, _html} = live(conn, course_path)
    render_async(lv)
    refute has_element?(lv, "#course-map-loading")
    assert has_element?(lv, "#course-map")
  end

  test "mounts and renders the course tree and default section", %{
    conn: conn,
    cohort: cohort,
    course: course,
    section: section
  } do
    {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")

    html = render_async(lv)

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

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
      )

    render_async(lv)
    assert has_element?(lv, "#map-block-#{block.id}")

    html =
      lv
      |> element("#map-block-#{block.id} a")
      |> render_click()

    assert html =~ ~r/Visits measured[\s\S]{0,80}?>\s*1\s*</
  end

  test "drills into a single block's metrics and shows the whole-cohort filter by default", %{
    conn: conn,
    cohort: cohort,
    course: course,
    section: section,
    block: block
  } do
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
      )

    html = render_async(lv)

    assert html =~ "Back to course map"
    assert html =~ "Whole cohort"
  end

  test "offers a submissions link only for gradable blocks, and only with grading.read", %{
    conn: conn,
    cohort: cohort,
    course: course,
    section: section,
    block: text_block,
    quiz_block: quiz_block
  } do
    grading_href_prefix = fn block -> "/teaching/grading?block_id=#{block.id}" end
    cohort_pair = "cohort_id=#{cohort.id}"

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{text_block.id}"
      )

    html = render_async(lv)

    # `text_block` isn't gradable, and this teacher lacks grading.read too -
    # the next block confirms which of the two actually gates the link.
    refute html =~ grading_href_prefix.(text_block)

    {:ok, lv, _html} =
      live(
        conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{quiz_block.id}"
      )

    html = render_async(lv)

    refute html =~ grading_href_prefix.(quiz_block)

    grading_role =
      insert(:role,
        permissions: ["cohorts.read", "courses.read", "engagement.read", "grading.read"]
      )

    grading_teacher = insert(:account, role: grading_role)
    grading_conn = init_test_session(conn, %{"account_id" => grading_teacher.id})

    {:ok, lv, _html} =
      live(
        grading_conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{quiz_block.id}"
      )

    html = render_async(lv)

    assert html =~ grading_href_prefix.(quiz_block)
    assert html =~ cohort_pair
  end

  test "lists cohort members in the student filter dropdown", %{
    conn: conn,
    cohort: cohort,
    course: course,
    student: student
  } do
    insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

    {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")

    html = render_async(lv)

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
    {:ok, lv, _html} =
      live(
        conn,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
      )

    html = render_async(lv)

    assert html =~ ~r/Visits measured[\s\S]{0,80}?>\s*0\s*</

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

    assert render(lv) =~ ~r/Visits measured[\s\S]{0,80}?>\s*1\s*</
  end

  describe "?view=students (\"Student Radar\")" do
    test "defaults to the content view when no ?view param is given", %{
      conn: conn,
      cohort: cohort,
      course: course
    } do
      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")

      html = render_async(lv)

      assert html =~ "Course Radar"
      refute html =~ "Slacking index"
    end

    test "shows level tiles and one row per student with the reasons behind their level", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      calm = insert(:account)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      insert(:cohort_membership, account_id: calm.id, cohort_id: cohort.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      # Two superficial-learning signals: 5s on a 100s text, a pasted answer.
      record_fast_dwell(student, cohort, block, section, now)
      record_heavy_paste(student, cohort, quiz_block, section, now)
      record_fast_dwell(calm, cohort, block, section, DateTime.add(now, -400 * 86_400))
      record(calm.id, cohort.id, Ecto.UUID.generate(), quiz_block, :viewport_enter, now)

      {:ok, lv, _html} = live(conn, students_path(cohort, course))
      render_async(lv)

      assert has_element?(lv, "#radar-level-tiles")
      assert lv |> element("#level-tile-superficial") |> render() =~ "1"
      assert lv |> element("#level-tile-on_track") |> render() =~ "1"

      row = lv |> element("#student-row-#{student.id}") |> render()
      assert row =~ "Skimming"
      assert row =~ "Too fast"
      assert row =~ "Pastes answers"

      assert has_element?(lv, "#student-row-#{calm.id}")
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

      {:ok, lv, _html} = live(conn, students_path(cohort, course))
      render_async(lv)

      # Default window (7 days) misses behavior from 10 days ago.
      refute lv |> element("#student-row-#{student.id}") |> render() =~ "Skimming"

      lv |> element("form[phx-change=change_window]") |> render_change(%{"window" => "all"})
      render_async(lv)

      assert lv |> element("#student-row-#{student.id}") |> render() =~ "Skimming"
    end

    test "clicking a student opens their card without recomputing the radar, and it closes", %{
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

      {:ok, lv, _html} = live(conn, students_path(cohort, course))
      render_async(lv)

      lv |> element("#student-row-#{student.id} a") |> render_click()

      assert_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students&window=7&student=#{student.id}"
      )

      refute has_element?(lv, "#student-radar-loading")
      assert has_element?(lv, "#student-drawer")

      signals = lv |> element("#student-signals") |> render()
      assert signals =~ "Network Basics · 1. Text"
      assert signals =~ "5 s"
      assert signals =~ "Pasted most of the answer"
      assert has_element?(lv, "#student-advice")

      assert has_element?(
               lv,
               ~s(#drawer-course-map[href="#{~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=&block_id=&account_id=#{student.id}"}"])
             )

      lv |> element("#student-drawer header a[aria-label]") |> render_click()
      refute has_element?(lv, "#student-drawer")
    end

    test "a low score after skipped theory says so in the card", %{
      conn: conn,
      cohort: cohort,
      course: course,
      quiz_block: quiz_block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record(student.id, cohort.id, Ecto.UUID.generate(), quiz_block, :viewport_enter, now)

      insert(:submission,
        account_id: student.id,
        block_id: quiz_block.id,
        status: :graded,
        score: 20
      )

      {:ok, lv, _html} =
        live(conn, students_path(cohort, course) <> "&student=#{student.id}")

      render_async(lv)

      assert lv |> element("#student-row-#{student.id}") |> render() =~ "Not mastering"
      assert lv |> element("#student-signals") |> render() =~ "never opened"
      assert lv |> element("#student-advice") |> render() =~ "go back to"
    end

    test "level tiles filter the table and clicking the active tile clears it", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      calm = insert(:account)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      insert(:cohort_membership, account_id: calm.id, cohort_id: cohort.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_fast_dwell(student, cohort, block, section, now)
      record_heavy_paste(student, cohort, quiz_block, section, now)
      record(calm.id, cohort.id, Ecto.UUID.generate(), quiz_block, :viewport_enter, now)

      {:ok, lv, _html} = live(conn, students_path(cohort, course))
      render_async(lv)

      lv |> element("#level-tile-superficial") |> render_click()
      assert has_element?(lv, "#student-row-#{student.id}")
      refute has_element?(lv, "#student-row-#{calm.id}")

      lv |> element("#level-tile-superficial") |> render_click()
      assert has_element?(lv, "#student-row-#{calm.id}")
    end

    test "the methodology modal opens and closes", %{conn: conn, cohort: cohort, course: course} do
      {:ok, lv, _html} = live(conn, students_path(cohort, course))
      render_async(lv)

      refute has_element?(lv, "#radar-methodology.modal-open")
      lv |> element("#open-methodology") |> render_click()
      assert has_element?(lv, "#radar-methodology.modal-open")
      render_click(lv, "close_methodology")
      refute has_element?(lv, "#radar-methodology.modal-open")
    end

    test "an unknown student in the URL is ignored", %{conn: conn, cohort: cohort, course: course} do
      {:ok, lv, _html} =
        live(conn, students_path(cohort, course) <> "&student=#{Ecto.UUID.generate()}")

      render_async(lv)
      refute has_element?(lv, "#student-drawer")
    end
  end

  describe "\"Course Radar\" content-flag sorting and weekly trend" do
    test "a block most students come back to is a problem spot on the course map", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      quiz_block: quiz_block,
      student: student
    } do
      intro_block = insert(:block, section: section, type: :text, order: 5)
      other_student = insert(:account)

      # Everyone reaches `quiz_block` first, then returns to `block`.
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

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")
      render_async(lv)

      assert lv |> element("#map-block-#{block.id}") |> render() =~ "Students come back"
      refute lv |> element("#map-block-#{intro_block.id}") |> render() =~ "badge"
      assert has_element?(lv, "#problem-#{block.id}")

      lv |> element("#toggle-problems") |> render_click()
      assert has_element?(lv, "#map-block-#{block.id}")
      refute has_element?(lv, "#map-block-#{intro_block.id}")
    end

    test "a section picked in the tree narrows the map to it", %{
      conn: conn,
      cohort: cohort,
      course: course,
      block: block
    } do
      other_section = insert(:section, course: course, title: "Crypto", order: 20)
      other_block = insert(:block, section: other_section, type: :text, order: 1)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")
      render_async(lv)
      assert has_element?(lv, "#map-block-#{block.id}")
      assert has_element?(lv, "#map-block-#{other_block.id}")

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{other_section.id}"
        )

      render_async(lv)
      refute has_element?(lv, "#map-block-#{block.id}")
      assert has_element?(lv, "#map-block-#{other_block.id}")
      assert has_element?(lv, "#map-whole-course")
    end

    test "with nothing going on there are no problem spots", %{
      conn: conn,
      cohort: cohort,
      course: course
    } do
      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")
      render_async(lv)

      assert has_element?(lv, "#problem-spots")
      refute has_element?(lv, "#problem-spots li")
    end

    test "the student lens shows that student's numbers and their problem spots", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
      student: student
    } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      record_fast_dwell(student, cohort, block, section, now)

      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")
      render_async(lv)

      lv
      |> element("form[phx-change=change_student]")
      |> render_change(%{"account_id" => student.id})

      render_async(lv)

      row = lv |> element("#map-block-#{block.id}") |> render()
      assert row =~ "5 s"
      assert row =~ "Too fast"
      assert lv |> element("#problem-spots") |> render() =~ "Where"
      assert has_element?(lv, "#problem-#{block.id}")
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

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      html = render_async(lv)

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
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      html = render_async(lv)

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

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      html = render_async(lv)

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
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      html = render_async(lv)

      config = chart_config_from_html(html, "dwell-histogram")
      assert Enum.sum(hd(config["data"]["datasets"])["data"]) == 0
    end

    test "the histogram is not rendered (default empty config) on the section/block-list view", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      html = render_async(lv)

      refute html =~ "Dwell distribution"
    end
  end

  describe "\"Course Radar\" tabs and period" do
    test "activity charts load only on their tab; a block skips them, coming back recomputes them",
         %{
           conn: conn,
           cohort: cohort,
           course: course,
           section: section,
           block: block,
           student: student
         } do
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}"
        )

      render_async(lv)
      assert has_element?(lv, "#course-map")
      refute has_element?(lv, "#course-charts")

      lv |> element("#course-tab-activity") |> render_click()
      render_async(lv)
      assert has_element?(lv, "#course-charts")
      heatmap_before = :sys.get_state(lv.pid).socket.assigns.heatmap_config

      record_fast_dwell(student, cohort, block, section, now)

      render_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=#{block.id}&account_id=&tab=activity"
      )

      assert :sys.get_state(lv.pid).socket.assigns.heatmap_config == heatmap_before

      render_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&block_id=&account_id=&tab=activity"
      )

      render_async(lv)
      assert :sys.get_state(lv.pid).socket.assigns.heatmap_config != heatmap_before
    end

    test "changing the period keeps the current section and tab", %{
      conn: conn,
      cohort: cohort,
      course: course
    } do
      other_section = insert(:section, course: course, order: 20)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{other_section.id}&tab=activity"
        )

      _ = render_async(lv)

      lv
      |> element("form[phx-change=change_course_window]")
      |> render_change(%{"window" => "30"})

      assert_patch(
        lv,
        ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{other_section.id}&block_id=&account_id=&course_window=30&tab=activity"
      )

      _ = render_async(lv)
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

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&tab=activity"
        )

      html = render_async(lv)

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
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&tab=activity"
        )

      html = render_async(lv)

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

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&tab=activity"
        )

      html = render_async(lv)

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
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&tab=activity"
        )

      html = render_async(lv)

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

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&tab=activity"
        )

      html = render_async(lv)

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
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&tab=activity"
        )

      html = render_async(lv)

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

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&tab=activity"
        )

      html = render_async(lv)

      config = chart_config_from_html(html, "nudge-correction-rate-chart")

      assert config["type"] == "bar"
      assert config["data"]["labels"] == ["Too fast"]
      assert [%{"data" => [100.0]}] = config["data"]["datasets"]
    end

    test "with no nudges at all, renders a valid empty chart", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?section_id=#{section.id}&tab=activity"
        )

      html = render_async(lv)

      config = chart_config_from_html(html, "nudge-correction-rate-chart")

      assert config["data"]["labels"] == []
      assert [%{"data" => []}] = config["data"]["datasets"]
    end
  end

  defp record(account_id, cohort_id, session_id, block, event_type, at) do
    Engagement.record_events(account_id, cohort_id, session_id, [
      %{block_id: block.id, section_id: block.section_id, event_type: event_type, occurred_at: at}
    ])
  end

  defp students_path(cohort, course),
    do: ~p"/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students"

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
