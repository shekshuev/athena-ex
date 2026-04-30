defmodule AthenaWeb.TeachingLive.InstructorFormComponentTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory
  alias Athena.Learning

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: ["instructors.read", "instructors.create", "instructors.update", "admin"]
      )

    account = insert(:account, role: role)

    conn = init_test_session(conn, %{"account_id" => account.id})
    %{conn: conn, current_user: account, admin: account}
  end

  describe "Instructor Form Component" do
    test "validates required fields on change", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teaching/instructors/new")

      html =
        lv
        |> form("#instructor-form", %{
          "instructor" => %{"title" => ""}
        })
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "creates a new instructor and links account via autocomplete", %{
      conn: conn,
      admin: admin
    } do
      account_to_link = insert(:account, login: "future_instructor")

      {:ok, lv, _html} = live(conn, ~p"/teaching/instructors/new")

      lv
      |> element("input[phx-keyup='search_accounts']")
      |> render_keyup(%{"value" => "future_instructor"})

      lv
      |> element("li", "future_instructor")
      |> render_click()

      lv
      |> form("#instructor-form", %{
        "instructor" => %{
          "title" => "Elixir Grandmaster",
          "bio" => "Loves building scalable systems."
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/teaching/instructors")

      assert render(lv) =~ "Instructor created successfully"

      {:ok, {instructors, _meta}} = Learning.list_instructors(admin, %{})
      assert length(instructors) == 1
      instructor = hd(instructors)

      assert instructor.title == "Elixir Grandmaster"
      assert instructor.bio == "Loves building scalable systems."
      assert instructor.owner_id == account_to_link.id
    end

    test "updates an existing instructor's title and bio", %{
      conn: conn,
      admin: admin
    } do
      instructor = insert(:instructor, title: "Old Title", bio: "Old Bio", owner_id: admin.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/instructors/#{instructor.id}/edit")

      lv
      |> form("#instructor-form", %{
        "instructor" => %{
          "title" => "Updated Title",
          "bio" => "Updated Bio"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/teaching/instructors")

      assert render(lv) =~ "Instructor updated successfully"

      {:ok, updated_instructor} = Learning.get_instructor(admin, instructor.id)

      assert updated_instructor.title == "Updated Title"
      assert updated_instructor.bio == "Updated Bio"
      assert updated_instructor.owner_id == instructor.owner_id
    end
  end

  describe "Permissions & ACL (Policies: own_only)" do
    setup %{conn: conn} do
      role =
        insert(:role,
          permissions: ["instructors.read", "instructors.create", "instructors.update"],
          policies: %{"instructors.update" => ["own_only"]}
        )

      instructor = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => instructor.id})

      %{conn: conn, instructor: instructor}
    end

    test "allows instructor to edit their own profile via form", %{
      conn: conn,
      instructor: instructor
    } do
      my_profile = insert(:instructor, title: "My Old Title", owner_id: instructor.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/instructors/#{my_profile.id}/edit")

      lv
      |> form("#instructor-form", %{
        "instructor" => %{
          "title" => "My Awesome New Title"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/teaching/instructors")
      assert render(lv) =~ "Instructor updated successfully"

      {:ok, updated} = Learning.get_instructor(instructor, my_profile.id)
      assert updated.title == "My Awesome New Title"
    end
  end
end
