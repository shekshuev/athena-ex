defmodule AthenaWeb.TeachingLive.CohortEngagementTest do
  # Not async for the same reason as the Player engagement tests: metrics
  # queries and the live PubSub roundtrip involve `Athena.Engagement`
  # processes outside the test process, which only have sandbox access when
  # the connection is shared (`async: false`).
  use AthenaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  import Athena.Factory

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
    block = insert(:block, section: section, type: :text, order: 10)
    student = insert(:account)

    %{
      conn: conn,
      teacher: teacher,
      cohort: cohort,
      course: course,
      section: section,
      block: block,
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
end
