defmodule AthenaWeb.StudioLive.GradingTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role = insert(:role, permissions: ["grading.read"])
    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Grading page (Index & Default Filters)" do
    test "should render the assignments list with default needs_review filter", %{conn: conn} do
      student1 = insert(:account, login: "johndoe")
      student2 = insert(:account, login: "janedoe")
      block1 = insert(:block, type: :quiz_exam)
      block2 = insert(:block, type: :code)

      insert(:submission,
        account_id: student1.id,
        block_id: block1.id,
        status: :needs_review
      )

      insert(:submission,
        account_id: student2.id,
        block_id: block2.id,
        status: :graded
      )

      {:ok, _lv, html} = live(conn, ~p"/studio/grading")

      assert html =~ "Assignments"
      assert html =~ "johndoe"
      assert html =~ "quiz_exam"
      assert html =~ "Needs review"
      assert html =~ "Grade"
      assert html =~ "hero-pencil-square"
      refute html =~ "janedoe"
    end

    test "should handle unknown accounts or blocks gracefully", %{conn: conn} do
      insert(:submission,
        account_id: Ecto.UUID.generate(),
        block_id: Ecto.UUID.generate(),
        status: :needs_review
      )

      {:ok, _lv, html} = live(conn, ~p"/studio/grading")

      assert html =~ "Unknown"
    end
  end

  describe "Grading page (Filtering)" do
    test "should update filter and render graded submissions", %{conn: conn} do
      student = insert(:account, login: "smart_student")
      block = insert(:block, type: :quiz_exam)

      insert(:submission,
        account_id: student.id,
        block_id: block.id,
        status: :graded,
        score: 95
      )

      {:ok, lv, _html} = live(conn, ~p"/studio/grading")

      html =
        lv
        |> form("form[phx-change='update_filter']", %{"status" => "graded"})
        |> render_change()

      assert html =~ "smart_student"
      assert html =~ "95 / 100"
      assert html =~ "Graded"

      assert html =~ "View"
      assert html =~ "hero-eye"
    end

    test "should clear filter and show all submissions when empty status is passed", %{conn: conn} do
      student = insert(:account, login: "any_student")
      block = insert(:block, type: :text)

      insert(:submission, account_id: student.id, block_id: block.id, status: :pending)

      {:ok, lv, _html} = live(conn, ~p"/studio/grading")

      html =
        lv
        |> form("form[phx-change='update_filter']", %{"status" => ""})
        |> render_change()

      assert html =~ "any_student"
      assert html =~ "Pending"
    end
  end

  describe "Permissions & ACL" do
    test "should redirect if user lacks grading.read permission", %{conn: conn} do
      role = insert(:role, permissions: [])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      assert {:error, redirect} = live(conn, ~p"/studio/grading")

      case redirect do
        {:redirect, %{to: _path}} -> assert true
        {:live_redirect, %{to: _path}} -> assert true
        _ -> flunk("Expected a redirect due to lack of permissions")
      end
    end
  end
end
