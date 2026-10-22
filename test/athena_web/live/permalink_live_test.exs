defmodule AthenaWeb.PermalinkLiveTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  defp insert_student, do: insert(:account, role: insert(:role, permissions: []))

  describe "/go/blocks/:id" do
    test "a cold (disconnected) load gets a real HTTP redirect for an editor", %{conn: conn} do
      editor = insert(:account)
      course = insert(:course, owner_id: editor.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      conn = init_test_session(conn, %{"account_id" => editor.id})
      conn = get(conn, ~p"/go/blocks/#{block.id}")

      assert redirected_to(conn, 302) ==
               ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}/blocks/#{block.id}"
    end

    test "an enrolled student connects and is live-redirected into the Player, anchored to the block",
         %{conn: conn} do
      student = insert_student()
      course = insert(:course, owner_id: Ecto.UUID.generate())
      insert(:enrollment, account_id: student.id, course_id: course.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      conn = init_test_session(conn, %{"account_id" => student.id})

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/go/blocks/#{block.id}")
      assert to == ~p"/learn/courses/#{course.id}/play/#{section.id}?block=#{block.id}"
    end

    test "unknown block renders a not-found page", %{conn: conn} do
      conn = init_test_session(conn, %{"account_id" => insert_student().id})

      {:ok, _lv, html} = live(conn, ~p"/go/blocks/#{Ecto.UUID.generate()}")

      assert html =~ "Not found"
    end

    test "a non-enrolled, non-editor viewer gets an access-denied page", %{conn: conn} do
      outsider = insert_student()
      course = insert(:course, owner_id: Ecto.UUID.generate())
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      conn = init_test_session(conn, %{"account_id" => outsider.id})

      {:ok, _lv, html} = live(conn, ~p"/go/blocks/#{block.id}")

      assert html =~ "Access denied"
    end
  end

  describe "/go/sections/:id" do
    test "an editor is redirected into the Builder at the section", %{conn: conn} do
      editor = insert(:account)
      course = insert(:course, owner_id: editor.id)
      section = insert(:section, course: course)

      conn = init_test_session(conn, %{"account_id" => editor.id})

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/go/sections/#{section.id}")
      assert to == ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}"
    end

    test "an enrolled student is redirected into the Player at the section (no block anchor)",
         %{conn: conn} do
      student = insert_student()
      course = insert(:course, owner_id: Ecto.UUID.generate())
      insert(:enrollment, account_id: student.id, course_id: course.id)
      section = insert(:section, course: course)
      # A section with no blocks of its own is a heading, not a "lesson" -
      # `Content.list_linear_lessons/4` drops it, so it would never be
      # reachable by a student regardless of this feature.
      insert(:block, section: section)

      conn = init_test_session(conn, %{"account_id" => student.id})

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/go/sections/#{section.id}")
      assert to == ~p"/learn/courses/#{course.id}/play/#{section.id}"
    end
  end
end
