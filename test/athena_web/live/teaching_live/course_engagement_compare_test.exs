defmodule AthenaWeb.TeachingLive.CourseEngagementCompareTest do
  # Not async, for the same reason as CohortEngagementTest - metrics queries
  # go through Athena.Engagement processes that only share the DB sandbox
  # connection when the test isn't async.
  use AthenaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  import Athena.Factory

  alias Athena.Content.EngagementRule
  alias Athena.Engagement

  setup %{conn: conn} do
    role = insert(:role, permissions: ["cohorts.read", "courses.read", "engagement.read"])
    teacher = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => teacher.id})

    course = insert(:course, title: "Advanced Hacking")
    section = insert(:section, course: course)

    block =
      insert(:block,
        section: section,
        type: :text,
        order: 10,
        engagement_rule: %EngagementRule{expected_seconds: 100}
      )

    %{conn: conn, teacher: teacher, course: course, section: section, block: block}
  end

  test "redirects when the teacher lacks engagement.read", %{course: course} do
    other_role = insert(:role, permissions: ["cohorts.read", "courses.read"])
    other_teacher = insert(:account, role: other_role)
    conn = build_conn() |> init_test_session(%{"account_id" => other_teacher.id})

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")
  end

  test "lists cohorts enrolled in the course, not cohorts enrolled elsewhere", %{
    conn: conn,
    course: course
  } do
    enrolled = insert(:cohort, name: "Enrolled Cohort")
    insert(:enrollment, course_id: course.id, cohort_id: enrolled.id)

    other_course = insert(:course)
    elsewhere = insert(:cohort, name: "Elsewhere Cohort")
    insert(:enrollment, course_id: other_course.id, cohort_id: elsewhere.id)

    {:ok, _lv, html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")

    assert html =~ "Enrolled Cohort"
    refute html =~ "Elsewhere Cohort"
  end

  test "with no cohorts enrolled, shows an empty state and a valid empty chart", %{
    conn: conn,
    course: course
  } do
    {:ok, _lv, html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")

    assert html =~ "No cohorts are enrolled in this course yet."

    config = chart_config_from_html(html, "cohort-compare-radar")
    assert config["data"]["datasets"] == []
  end

  test "defaults to selecting every enrolled cohort (under the cap) and plots one dataset each",
       %{
         conn: conn,
         course: course
       } do
    cohort_a = insert(:cohort, name: "Cohort A")
    cohort_b = insert(:cohort, name: "Cohort B")
    insert(:enrollment, course_id: course.id, cohort_id: cohort_a.id)
    insert(:enrollment, course_id: course.id, cohort_id: cohort_b.id)

    {:ok, _lv, html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")

    config = chart_config_from_html(html, "cohort-compare-radar")
    labels = Enum.map(config["data"]["datasets"], & &1["label"])

    assert Enum.sort(labels) == ["Cohort A", "Cohort B"]
  end

  test "toggling a cohort off removes its dataset from the chart", %{
    conn: conn,
    course: course
  } do
    cohort_a = insert(:cohort, name: "Cohort A")
    cohort_b = insert(:cohort, name: "Cohort B")
    insert(:enrollment, course_id: course.id, cohort_id: cohort_a.id)
    insert(:enrollment, course_id: course.id, cohort_id: cohort_b.id)

    {:ok, lv, _html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")

    html =
      lv
      |> element("button[phx-value-cohort_id='#{cohort_a.id}']")
      |> render_click()

    config = chart_config_from_html(html, "cohort-compare-radar")
    labels = Enum.map(config["data"]["datasets"], & &1["label"])

    assert labels == ["Cohort B"]
  end

  test "each cohort's radar values reflect its own behavior independently", %{
    conn: conn,
    course: course,
    section: section,
    block: block
  } do
    fast_cohort = insert(:cohort, name: "Fast Cohort")
    calm_cohort = insert(:cohort, name: "Calm Cohort")
    insert(:enrollment, course_id: course.id, cohort_id: fast_cohort.id)
    insert(:enrollment, course_id: course.id, cohort_id: calm_cohort.id)

    fast_student = insert(:account)
    calm_student = insert(:account)
    insert(:cohort_membership, account_id: fast_student.id, cohort_id: fast_cohort.id)
    insert(:cohort_membership, account_id: calm_student.id, cohort_id: calm_cohort.id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    fast_session = Ecto.UUID.generate()
    calm_session = Ecto.UUID.generate()

    # fast_cohort's only student fast-dwells (5s against a 100s
    # expectation); calm_cohort's only student dwells right at the
    # expectation, triggering nothing.
    Engagement.record_events(fast_student.id, fast_cohort.id, fast_session, [
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

    Engagement.record_events(calm_student.id, calm_cohort.id, calm_session, [
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
        occurred_at: DateTime.add(now, 100, :second)
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")

    config = chart_config_from_html(html, "cohort-compare-radar")
    axes = config["data"]["labels"]
    fast_dwell_index = Enum.find_index(axes, &(&1 == "fast dwell"))

    fast_dataset = Enum.find(config["data"]["datasets"], &(&1["label"] == "Fast Cohort"))
    calm_dataset = Enum.find(config["data"]["datasets"], &(&1["label"] == "Calm Cohort"))

    assert Enum.at(fast_dataset["data"], fast_dwell_index) == 1.0
    assert Enum.at(calm_dataset["data"], fast_dwell_index) == 0.0
  end

  test "the period picker changes which window of behavior is counted", %{
    conn: conn,
    course: course,
    section: section,
    block: block
  } do
    cohort = insert(:cohort, name: "Only Cohort")
    insert(:enrollment, course_id: course.id, cohort_id: cohort.id)

    student = insert(:account)
    insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

    old_at =
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-10 * 86_400, :second)

    session = Ecto.UUID.generate()

    Engagement.record_events(student.id, cohort.id, session, [
      %{
        block_id: block.id,
        section_id: section.id,
        event_type: :viewport_enter,
        occurred_at: old_at
      },
      %{
        block_id: block.id,
        section_id: section.id,
        event_type: :viewport_exit,
        occurred_at: DateTime.add(old_at, 5, :second)
      }
    ])

    {:ok, lv, html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")

    config = chart_config_from_html(html, "cohort-compare-radar")
    axes = config["data"]["labels"]
    fast_dwell_index = Enum.find_index(axes, &(&1 == "fast dwell"))
    dataset = hd(config["data"]["datasets"])

    # Default window (7 days) misses behavior from 10 days ago.
    assert Enum.at(dataset["data"], fast_dwell_index) == 0.0

    html =
      lv |> element("form[phx-change=change_window]") |> render_change(%{"window" => "all"})

    config = chart_config_from_html(html, "cohort-compare-radar")
    dataset = hd(config["data"]["datasets"])
    assert Enum.at(dataset["data"], fast_dwell_index) == 1.0
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
