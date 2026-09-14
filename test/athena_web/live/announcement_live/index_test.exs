defmodule AthenaWeb.AnnouncementLive.IndexTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Announcements
  alias Athena.Learning.Cohorts

  setup %{conn: conn} do
    role = insert(:role, permissions: [])
    user = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => user.id})
    %{conn: conn, user: user}
  end

  describe "Announcements feed" do
    test "loads without any announcements.* permission and shows the empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/announcements")

      assert html =~ "Announcements"
      assert html =~ "No announcements yet"
    end

    test "shows global announcements and the user's own cohort's, not other cohorts'", %{
      conn: conn,
      user: user
    } do
      admin_role = insert(:role, permissions: ["admin"])
      admin = insert(:account, role: admin_role)

      {:ok, my_cohort} = Cohorts.create_cohort(admin, %{"name" => "My Cohort"})
      {:ok, other_cohort} = Cohorts.create_cohort(admin, %{"name" => "Other Cohort"})
      insert(:cohort_membership, account_id: user.id, cohort_id: my_cohort.id)

      {:ok, _} =
        Announcements.create_announcement(admin, %{
          "title" => "Global News",
          "body" => "Hello everyone",
          "scope" => "global"
        })

      {:ok, _} =
        Announcements.create_announcement(admin, %{
          "title" => "My Cohort News",
          "body" => "Hello",
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      {:ok, _} =
        Announcements.create_announcement(admin, %{
          "title" => "Other Cohort News",
          "body" => "Hello",
          "scope" => "cohort",
          "cohort_id" => other_cohort.id
        })

      {:ok, _lv, html} = live(conn, ~p"/announcements")

      assert html =~ "Global News"
      assert html =~ "My Cohort News"
      refute html =~ "Other Cohort News"
    end
  end
end
