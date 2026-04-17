defmodule AthenaWeb.TeachingLive.CohortAccessTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "cohorts.read",
          "cohorts.update",
          "courses.read"
        ]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Cohort Access Studio" do
    setup do
      cohort = insert(:cohort, name: "CyberSec 101")
      course = insert(:course, title: "Advanced Hacking")
      section = insert(:section, course: course, title: "Network Basics")
      block = insert(:block, section: section, content: %{"text" => "Scan the ports"})

      %{cohort: cohort, course: course, section: section, block: block}
    end

    test "mounts and renders the course tree and default section", %{
      conn: conn,
      cohort: cohort,
      course: course
    } do
      {:ok, _lv, html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/access/#{course.id}")

      assert html =~ "CyberSec 101"
      assert html =~ "Advanced Hacking"
      assert html =~ "Network Basics"
      assert html =~ "Scan the ports"
      assert html =~ "Blocks in this Section"
    end

    test "focuses on a specific block when block_id is in params", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section,
      block: block
    } do
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/teaching/cohorts/#{cohort.id}/access/#{course.id}?section_id=#{section.id}&block_id=#{block.id}"
        )

      assert html =~ "Back to Section"
      refute html =~ "Blocks in this Section"
    end

    test "saves a new override and clears it", %{
      conn: conn,
      cohort: cohort,
      course: course,
      section: section
    } do
      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/access/#{course.id}")

      html =
        lv
        |> form("form", %{
          "resource_type" => "section",
          "resource_id" => section.id,
          "visibility" => "hidden",
          "unlock_at" => "",
          "lock_at" => ""
        })
        |> render_submit()

      assert html =~ "Access override saved successfully."
      assert html =~ "Active Override"

      overrides = Learning.list_cohort_course_overrides(cohort.id, course.id)
      assert length(overrides) == 1
      assert hd(overrides).visibility == :hidden

      html =
        lv
        |> element("button[title='Clear Exception']")
        |> render_click()

      assert html =~ "Override removed. Inheriting global rules."
      refute html =~ "Active Override"

      assert Learning.list_cohort_course_overrides(cohort.id, course.id) == []
    end

    test "form visibility changes dynamically without saving", %{
      conn: conn,
      cohort: cohort,
      course: course
    } do
      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/access/#{course.id}")

      html =
        lv
        |> form("form")
        |> render_change(%{"visibility" => "restricted"})

      assert html =~ "Unlock Time"
      assert html =~ "Lock Time"
    end
  end
end
