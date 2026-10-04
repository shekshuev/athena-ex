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

    {:ok, lv, _html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")

    html = render_async(lv)

    assert html =~ "Enrolled Cohort"
    refute html =~ "Elsewhere Cohort"
  end

  test "with no cohorts enrolled, shows an empty state and no table", %{
    conn: conn,
    course: course
  } do
    {:ok, lv, _html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")

    html = render_async(lv)

    assert html =~ "No cohorts are enrolled in this course yet."
    refute has_element?(lv, "#cohort-compare-table")
  end

  test "defaults to every enrolled cohort, one column each, and toggling one off drops it", %{
    conn: conn,
    course: course
  } do
    cohort_a = insert(:cohort, name: "Cohort A")
    cohort_b = insert(:cohort, name: "Cohort B")
    insert(:enrollment, course_id: course.id, cohort_id: cohort_a.id)
    insert(:enrollment, course_id: course.id, cohort_id: cohort_b.id)

    {:ok, lv, _html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")
    render_async(lv)

    assert has_element?(lv, "#cell-score-#{cohort_a.id}")
    assert has_element?(lv, "#cell-score-#{cohort_b.id}")

    lv |> element("button[phx-value-cohort_id='#{cohort_a.id}']") |> render_click()
    render_async(lv)

    refute has_element?(lv, "#cell-score-#{cohort_a.id}")
    assert has_element?(lv, "#cell-score-#{cohort_b.id}")
  end

  test "a clearly weaker group is marked, explained in words and in the topics matrix", %{
    conn: conn,
    course: course,
    section: section
  } do
    quiz = insert(:block, section: section, type: :quiz_question, order: 20)
    weak = insert(:cohort, name: "Weak Cohort")
    strong = insert(:cohort, name: "Strong Cohort")

    for {cohort, score} <- [{weak, 20}, {strong, 90}] do
      insert(:enrollment, course_id: course.id, cohort_id: cohort.id)

      for _ <- 1..2 do
        student = insert(:account)
        insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

        insert(:submission,
          account_id: student.id,
          block_id: quiz.id,
          status: :graded,
          score: score
        )
      end
    end

    {:ok, lv, _html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")
    render_async(lv)

    assert has_element?(lv, "#cell-score-#{weak.id}[data-deviation='2-bad']")
    assert has_element?(lv, "#cell-score-#{strong.id}[data-deviation='2-good']")
    assert lv |> element("#indicator-score td.bg-base-200\\/50") |> render() =~ "55"

    insights = lv |> element("#compare-insights") |> render()
    assert insights =~ "Weak Cohort"
    assert insights =~ "20 against 55"

    assert lv |> element("#topic-#{section.id}-#{weak.id}") |> render() =~ "20"
    assert lv |> element("#topic-#{section.id}-#{strong.id}") |> render() =~ "90"

    lv |> element("#matrix-completion") |> render_click()

    assert assert_patch(lv) =~ "matrix=completion"

    assert lv |> element("#topic-#{section.id}-#{weak.id}") |> render() =~ "0%"
  end

  test "every cell opens that group's radar, filtered to the students behind the number", %{
    conn: conn,
    course: course
  } do
    cohort = insert(:cohort, name: "Only Cohort")
    insert(:enrollment, course_id: course.id, cohort_id: cohort.id)

    {:ok, lv, _html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")
    render_async(lv)

    assert has_element?(
             lv,
             ~s(#cell-inactive-#{cohort.id}[href="/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students&window=7&level=inactive"])
           )

    assert has_element?(
             lv,
             ~s(#cell-slacking-#{cohort.id}[href$="level=superficial"])
           )
  end

  test "the period picker changes which window of behavior is counted", %{
    conn: conn,
    course: course,
    section: section,
    block: block
  } do
    cohort = insert(:cohort, name: "Only Cohort")
    insert(:enrollment, course_id: course.id, cohort_id: cohort.id)

    recent = insert(:account)
    earlier = insert(:account)
    insert(:cohort_membership, account_id: recent.id, cohort_id: cohort.id)
    insert(:cohort_membership, account_id: earlier.id, cohort_id: cohort.id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {student, at} <- [{recent, now}, {earlier, DateTime.add(now, -10 * 86_400)}] do
      Engagement.record_events(student.id, cohort.id, Ecto.UUID.generate(), [
        %{
          block_id: block.id,
          section_id: section.id,
          event_type: :viewport_enter,
          occurred_at: at
        }
      ])
    end

    {:ok, lv, _html} = live(conn, ~p"/teaching/courses/#{course.id}/engagement/compare")
    render_async(lv)

    # Within 7 days, one of the two students did nothing.
    assert lv |> element("#cell-inactive-#{cohort.id}") |> render() =~ "50%"

    lv |> element("form[phx-change=change_window]") |> render_change(%{"window" => "all"})
    render_async(lv)

    assert lv |> element("#cell-inactive-#{cohort.id}") |> render() =~ "0%"
  end
end
