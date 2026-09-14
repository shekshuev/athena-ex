defmodule AthenaWeb.AdminLive.AnnouncementsTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning.Cohorts

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "admin",
          "announcements.read",
          "announcements.create",
          "announcements.update",
          "announcements.delete"
        ]
      )

    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Announcements page (Index)" do
    test "renders the announcements list", %{conn: conn, admin: admin} do
      {:ok, _} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "Welcome",
          "body" => "Hello everyone",
          "scope" => "global"
        })

      {:ok, _lv, html} = live(conn, ~p"/admin/announcements")

      assert html =~ "Announcements"
      assert html =~ "Create Announcement"
      assert html =~ "Welcome"
    end

    test "handles search functionality and maintains params", %{conn: conn, admin: admin} do
      Athena.Announcements.create_announcement(admin, %{
        "title" => "Special Notice",
        "body" => "Hello",
        "scope" => "global"
      })

      Athena.Announcements.create_announcement(admin, %{
        "title" => "Common Notice",
        "body" => "Hello",
        "scope" => "global"
      })

      {:ok, lv, _html} = live(conn, ~p"/admin/announcements")

      html =
        lv
        |> form("form[phx-change='search']", %{"search" => "Special"})
        |> render_change()

      assert html =~ "Special Notice"
      refute html =~ "Common Notice"
    end
  end

  describe "Announcements page (Create/Edit)" do
    test "creates a global announcement", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/announcements/new")

      lv
      |> form("#announcement-form", %{
        "announcement" => %{
          "title" => "Brand New",
          "body" => "Hello there",
          "scope" => "global"
        }
      })
      |> render_submit()

      assert render(lv) =~ "Brand New"
    end

    test "creates a cohort announcement", %{conn: conn, admin: admin} do
      {:ok, cohort} = Cohorts.create_cohort(admin, %{"name" => "Bootcamp"})

      {:ok, lv, _html} = live(conn, ~p"/admin/announcements/new")

      # scope must be set first so the conditional cohort_id field renders
      lv
      |> form("#announcement-form", %{
        "announcement" => %{
          "title" => "Cohort News",
          "body" => "Hello cohort",
          "scope" => "cohort"
        }
      })
      |> render_change()

      lv
      |> form("#announcement-form", %{
        "announcement" => %{
          "title" => "Cohort News",
          "body" => "Hello cohort",
          "scope" => "cohort",
          "cohort_id" => cohort.id
        }
      })
      |> render_submit()

      assert render(lv) =~ "Cohort News"
    end
  end

  describe "Announcements page (Delete action)" do
    test "deletes the announcement when confirmed", %{conn: conn, admin: admin} do
      {:ok, announcement} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "Doomed",
          "body" => "Hello",
          "scope" => "global"
        })

      {:ok, lv, _html} = live(conn, ~p"/admin/announcements")

      lv
      |> element("button[phx-click='delete_click'][phx-value-id='#{announcement.id}']")
      |> render_click()

      html = render_click(lv, "confirm_delete")

      assert html =~ "Announcement deleted successfully"
      refute html =~ "Doomed"
    end
  end

  describe "Permissions & ACL" do
    test "user without announcements.read is redirected away from the page", %{conn: conn} do
      role = insert(:role, permissions: [])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/admin/announcements")
    end

    test "instructor sees only global + their instructed cohort's announcements", %{
      conn: _conn,
      admin: admin
    } do
      instructor_role =
        insert(:role,
          permissions: [
            "announcements.read",
            "announcements.create",
            "announcements.update",
            "announcements.delete"
          ]
        )

      instructor_account = insert(:account, role: instructor_role)
      instructor_profile = insert(:instructor, owner_id: instructor_account.id)

      {:ok, my_cohort} =
        Cohorts.create_cohort(admin, %{
          "name" => "Mine",
          "instructor_ids" => [instructor_profile.id]
        })

      {:ok, other_cohort} = Cohorts.create_cohort(admin, %{"name" => "Not mine"})

      {:ok, _} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "Global",
          "body" => "Hi",
          "scope" => "global"
        })

      {:ok, _} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "MineNews",
          "body" => "Hi",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      {:ok, _} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "NotMineNews",
          "body" => "Hi",
          "scope" => "cohort",
          "cohort_id" => other_cohort.id
        })

      instructor_conn =
        build_conn() |> init_test_session(%{"account_id" => instructor_account.id})

      {:ok, _lv, html} = live(instructor_conn, ~p"/admin/announcements")

      assert html =~ "Global"
      assert html =~ "MineNews"
      refute html =~ "NotMineNews"
    end

    test "instructor cannot create a global announcement via the form", %{conn: _conn} do
      instructor_role =
        insert(:role,
          permissions: ["announcements.read", "announcements.create"]
        )

      instructor_account = insert(:account, role: instructor_role)

      instructor_conn =
        build_conn() |> init_test_session(%{"account_id" => instructor_account.id})

      {:ok, _lv, html} = live(instructor_conn, ~p"/admin/announcements/new")

      refute html =~ ~s(option value="global")
      assert html =~ ~s(option value="cohort")
    end
  end
end
