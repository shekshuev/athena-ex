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
          "body" => tiptap_doc("Hello everyone"),
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
        "body" => tiptap_doc("Hello"),
        "scope" => "global"
      })

      Athena.Announcements.create_announcement(admin, %{
        "title" => "Common Notice",
        "body" => tiptap_doc("Hello"),
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

      # The TipTap body is normally set client-side by the JS hook into a
      # hidden input, which Phoenix.LiveViewTest's DOM-backed `form/3`
      # override refuses to fake (hidden fields must keep their rendered
      # value) – so, like this codebase's other TipTap-hidden-input flows
      # (e.g. player_test.exs's code/answer submissions), scrape the form
      # with `form/2` (no overrides) and pass the real payload to
      # `render_submit/2` directly instead, bypassing that DOM check.
      lv
      |> form("#announcement-form")
      |> render_submit(%{
        "announcement" => %{
          "title" => "Brand New",
          "body" => Jason.encode!(tiptap_doc("Hello there")),
          "scope" => "global"
        }
      })

      assert_redirect(lv, ~p"/admin/announcements")
      assert Athena.Repo.get_by(Athena.Announcements.Announcement, title: "Brand New")
    end

    test "a body survives a validate round-trip and still saves", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/announcements/new")

      body = Jason.encode!(tiptap_doc("Hello there"))

      # Any change re-renders the hidden body input. The TipTap hook lives in
      # a `phx-update="ignore"` container and does not rewrite the input on a
      # patch, so what the browser submits next is whatever the server put
      # there - which is how this used to accumulate a layer of JSON quoting
      # per keystroke until the body no longer decoded to a document and the
      # save failed with nothing shown on screen.
      lv
      |> form("#announcement-form")
      |> render_change(%{
        "announcement" => %{"title" => "Round trip", "body" => body, "scope" => "global"}
      })

      rendered_body =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query_by_id("announcement-body-input")
        |> LazyHTML.attribute("value")
        |> List.first()

      assert rendered_body == body

      lv
      |> form("#announcement-form")
      |> render_submit(%{
        "announcement" => %{
          "title" => "Round trip",
          "body" => rendered_body,
          "scope" => "global"
        }
      })

      assert_redirect(lv, ~p"/admin/announcements")

      saved = Athena.Repo.get_by(Athena.Announcements.Announcement, title: "Round trip")
      assert saved
      assert saved.body["type"] == "doc"
      assert Athena.Announcements.preview_text(saved.body) =~ "Hello there"
    end

    test "creates a cohort announcement via the cohort search box", %{conn: conn, admin: admin} do
      {:ok, cohort} = Cohorts.create_cohort(admin, %{"name" => "Bootcamp"})

      {:ok, lv, _html} = live(conn, ~p"/admin/announcements/new")

      # scope must be set first so the conditional cohort search box renders
      lv
      |> form("#announcement-form")
      |> render_change(%{
        "announcement" => %{
          "title" => "Cohort News",
          "body" => Jason.encode!(tiptap_doc("Hello cohort")),
          "scope" => "cohort"
        }
      })

      lv
      |> element("input[phx-keyup='search_cohorts']")
      |> render_keyup(%{"value" => "Boot"})

      lv
      |> element("li[phx-value-id='#{cohort.id}']")
      |> render_click()

      lv
      |> form("#announcement-form")
      |> render_submit(%{
        "announcement" => %{
          "title" => "Cohort News",
          "body" => Jason.encode!(tiptap_doc("Hello cohort")),
          "scope" => "cohort"
        }
      })

      assert_redirect(lv, ~p"/admin/announcements")

      saved = Athena.Repo.get_by(Athena.Announcements.Announcement, title: "Cohort News")
      assert saved.cohort_id == cohort.id
    end

    test "edits an existing announcement, including marking it important", %{
      conn: conn,
      admin: admin
    } do
      {:ok, announcement} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "Original",
          "body" => tiptap_doc("Hello"),
          "scope" => "global"
        })

      {:ok, lv, html} = live(conn, ~p"/admin/announcements/#{announcement.id}/edit")
      assert html =~ "Edit Announcement"

      lv
      |> form("#announcement-form")
      |> render_submit(%{
        "announcement" => %{
          "title" => "Updated title",
          "body" => Jason.encode!(tiptap_doc("Hello")),
          "scope" => "global",
          "important" => "true"
        }
      })

      assert_redirect(lv, ~p"/admin/announcements")

      updated = Athena.Repo.get!(Athena.Announcements.Announcement, announcement.id)
      assert updated.title == "Updated title"
      assert updated.important == true
    end
  end

  describe "Announcements page (link modal)" do
    test "opening, saving, and removing a link pushes the matching event to the editor",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/announcements/new")

      html =
        render_click(lv, "open_link_modal", %{
          "block_id" => "announcement-body",
          "href" => nil,
          "text" => "some text"
        })

      assert html =~ "link-form"

      lv
      |> form("#link-form", %{"link" => %{"href" => "https://example.com", "text" => "Example"}})
      |> render_submit()

      assert_push_event(lv, "apply_link", %{
        block_id: "announcement-body",
        href: "https://example.com",
        text: "Example"
      })

      refute has_element?(lv, "#link-modal")

      render_click(lv, "open_link_modal", %{
        "block_id" => "announcement-body",
        "href" => "https://example.com",
        "text" => "Example"
      })

      lv
      |> element("button[phx-click='remove_link']")
      |> render_click()

      assert_push_event(lv, "remove_link", %{block_id: "announcement-body"})
    end

    test "cancelling the link modal closes it without pushing an event", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/announcements/new")

      render_click(lv, "open_link_modal", %{
        "block_id" => "announcement-body",
        "href" => nil,
        "text" => nil
      })

      assert has_element?(lv, "#link-modal")

      render_click(lv, "cancel_link_modal")

      refute has_element?(lv, "#link-modal")
    end
  end

  describe "Announcements page (Delete action)" do
    test "deletes the announcement when confirmed", %{conn: conn, admin: admin} do
      {:ok, announcement} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "Doomed",
          "body" => tiptap_doc("Hello"),
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
          "body" => tiptap_doc("Hi"),
          "scope" => "global"
        })

      {:ok, _} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "MineNews",
          "body" => tiptap_doc("Hi"),
          "scope" => "cohort",
          "cohort_id" => my_cohort.id
        })

      {:ok, _} =
        Athena.Announcements.create_announcement(admin, %{
          "title" => "NotMineNews",
          "body" => tiptap_doc("Hi"),
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

    test "an instructor's form only offers the cohort audience, never global", %{
      conn: _conn,
      admin: admin
    } do
      instructor_role =
        insert(:role, permissions: ["announcements.read", "announcements.create"])

      instructor_account = insert(:account, role: instructor_role)
      instructor_profile = insert(:instructor, owner_id: instructor_account.id)

      {:ok, _cohort} =
        Cohorts.create_cohort(admin, %{
          "name" => "Mine",
          "instructor_ids" => [instructor_profile.id]
        })

      instructor_conn =
        build_conn() |> init_test_session(%{"account_id" => instructor_account.id})

      {:ok, _lv, html} = live(instructor_conn, ~p"/admin/announcements/new")

      refute html =~ ~s(option value="global")
      assert html =~ ~s(option value="cohort")
    end

    test "a non-admin who instructs no cohort sees a disabled-state notice, not a dead-end form",
         %{conn: _conn} do
      role = insert(:role, permissions: ["announcements.read", "announcements.create"])
      account = insert(:account, role: role)

      conn = build_conn() |> init_test_session(%{"account_id" => account.id})

      {:ok, _lv, html} = live(conn, ~p"/admin/announcements/new")

      refute html =~ ~s(option value="global")
      refute html =~ ~s(option value="cohort")
      refute html =~ ~s(id="announcement-form")
      assert html =~ "not an instructor of any cohort"
    end
  end
end
