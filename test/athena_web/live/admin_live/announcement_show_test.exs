defmodule AthenaWeb.AdminLive.AnnouncementShowTest do
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Announcements
  alias Athena.Learning.Cohorts

  setup %{conn: conn} do
    admin = insert(:account, role: insert(:role, permissions: ["admin"]))
    {:ok, group} = Cohorts.create_cohort(admin, %{"name" => "Alpha"})
    {:ok, team} = Cohorts.create_cohort(admin, %{"name" => "Beta", "type" => "team"})

    {:ok, announcement} =
      Announcements.create_announcement(admin, %{
        "title" => "Scheduled news",
        "body" => tiptap_doc("Hello everyone"),
        "scope" => "cohort",
        "cohort_ids" => [group.id, team.id],
        "important" => true,
        "starts_at" => DateTime.add(DateTime.utc_now(), 3600),
        "ends_at" => DateTime.add(DateTime.utc_now(), 7200)
      })

    %{
      conn: init_test_session(conn, %{"account_id" => admin.id}),
      announcement: announcement,
      group: group,
      team: team
    }
  end

  test "list renders separate recipient badges and a view link", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/admin/announcements")
    audience = "#announcement-audience-#{ctx.announcement.id}"
    assert has_element?(view, "#{audience} .badge", "Alpha")
    assert has_element?(view, "#{audience} .badge", "Beta")
    refute has_element?(view, "#{audience} .badge", "Cohort:")
    refute has_element?(view, "#{audience} .badge", "Team:")

    assert has_element?(
             view,
             "#view-announcement-#{ctx.announcement.id}[href='/admin/announcements/#{ctx.announcement.id}']"
           )
  end

  test "admin previews a scheduled announcement with its settings", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/admin/announcements/#{ctx.announcement.id}")
    assert has_element?(view, "#announcement-preview h3", ctx.announcement.title)
    assert has_element?(view, "#announcement-preview.border-warning")
    assert has_element?(view, "#tiptap-view-#{ctx.announcement.id}[data-readonly='true']")
    assert has_element?(view, "#announcement-audience .badge", "Alpha")
    assert has_element?(view, "#announcement-audience .badge", "Beta")

    for id <- ~w(author created-at updated-at starts-at ends-at important) do
      assert has_element?(view, "#announcement-#{id}")
    end

    assert has_element?(view, "#edit-announcement")
    assert has_element?(view, "#back-to-announcements")
  end

  test "reader cannot open an announcement outside their instructed cohorts", ctx do
    reader = insert(:account, role: insert(:role, permissions: ["announcements.read"]))
    conn = init_test_session(ctx.conn, %{"account_id" => reader.id})

    assert {:error, {:redirect, %{to: "/admin/announcements"}}} =
             live(conn, ~p"/admin/announcements/#{ctx.announcement.id}")
  end

  test "reader can preview a shared announcement for their cohort without edit access", ctx do
    reader = insert(:account, role: insert(:role, permissions: ["announcements.read"]))
    instructor = insert(:instructor, owner_id: reader.id)
    admin = insert(:account, role: insert(:role, permissions: ["admin"]))
    {:ok, _} = Cohorts.update_cohort(admin, ctx.group, %{"instructor_ids" => [instructor.id]})
    conn = init_test_session(ctx.conn, %{"account_id" => reader.id})
    {:ok, view, _} = live(conn, ~p"/admin/announcements/#{ctx.announcement.id}")
    assert has_element?(view, "#announcement-preview")
    refute has_element?(view, "#edit-announcement")
  end

  test "missing announcement redirects to the list", ctx do
    assert {:error, {:redirect, %{to: "/admin/announcements"}}} =
             live(ctx.conn, ~p"/admin/announcements/#{Ecto.UUID.generate()}")
  end

  test "user without read permission cannot open the preview", ctx do
    user = insert(:account, role: insert(:role, permissions: []))
    conn = init_test_session(ctx.conn, %{"account_id" => user.id})

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/admin/announcements/#{ctx.announcement.id}")
  end
end
