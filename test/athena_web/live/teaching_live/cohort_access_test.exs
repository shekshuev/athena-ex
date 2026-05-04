defmodule AthenaWeb.TeachingLive.CohortAccessTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning
  alias Athena.Learning.Cohorts

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "cohorts.read",
          "cohorts.update",
          "courses.read",
          "courses.update"
        ]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Cohort Access Studio (Happy Path)" do
    setup %{admin: admin} do
      cohort = insert(:cohort, name: "CyberSec 101", owner_id: admin.id)
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

  describe "Permissions & ACL (Missing Permissions)" do
    setup %{conn: conn} do
      role = insert(:role, permissions: ["cohorts.read", "courses.read"])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})
      %{conn: conn, limited_user: limited_user}
    end

    test "shows error flash if user tries to save override", %{conn: conn} do
      cohort = insert(:cohort)
      course = insert(:course)
      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/access/#{course.id}")

      html =
        render_hook(lv, "save_override", %{
          "resource_type" => "section",
          "resource_id" => Ecto.UUID.generate(),
          "visibility" => ""
        })

      assert html =~ "Permission denied."
    end

    test "shows error flash if user tries to clear override", %{conn: conn} do
      cohort = insert(:cohort)
      course = insert(:course)
      {:ok, lv, _html} = live(conn, ~p"/teaching/cohorts/#{cohort.id}/access/#{course.id}")

      html =
        render_hook(lv, "clear_override", %{
          "resource_type" => "section",
          "resource_id" => Ecto.UUID.generate()
        })

      assert html =~ "Permission denied."
    end
  end

  describe "Permissions & ACL (Policies: own_only)" do
    setup %{conn: conn} do
      role =
        insert(:role,
          permissions: [
            "cohorts.read",
            "cohorts.update",
            "courses.read",
            "courses.update"
          ],
          policies: %{
            "cohorts.read" => ["own_only"],
            "cohorts.update" => ["own_only"],
            "courses.read" => ["own_only"],
            "courses.update" => ["own_only"]
          }
        )

      instructor = insert(:account, role: role)
      inst_profile = insert(:instructor, owner_id: instructor.id)
      conn = init_test_session(conn, %{"account_id" => instructor.id})

      %{conn: conn, instructor: instructor, inst_profile: inst_profile}
    end

    test "allows override if instructor owns the cohort", %{
      conn: conn,
      instructor: instructor
    } do
      cohort = insert(:cohort, owner_id: instructor.id)
      course = insert(:course, owner_id: Ecto.UUID.generate())
      section = insert(:section, course: course)

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
    end

    test "allows override if instructor is a CO-INSTRUCTOR", %{
      conn: conn,
      inst_profile: inst_profile
    } do
      super_admin = insert(:account, role: insert(:role, permissions: ["admin"]))

      cohort = insert(:cohort, owner_id: super_admin.id)
      Cohorts.update_cohort(super_admin, cohort, %{"instructor_ids" => [inst_profile.id]})

      course = insert(:course, owner_id: Ecto.UUID.generate())
      section = insert(:section, course: course)

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
    end

    test "redirects with error on mount if instructor tries to access a cohort they don't own and are not part of",
         %{
           conn: conn
         } do
      cohort = insert(:cohort, owner_id: Ecto.UUID.generate())
      course = insert(:course, owner_id: Ecto.UUID.generate())

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/teaching/cohorts/#{cohort.id}/access/#{course.id}")

      assert to == "/teaching/cohorts/#{cohort.id}"
      assert flash["error"] == "Access denied or course not found."
    end
  end
end
