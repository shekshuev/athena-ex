defmodule AthenaWeb.TeachingLive.GradingTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  setup %{conn: conn} do
    role = insert(:role, permissions: ["grading.read", "cohorts.read"])
    admin = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => admin.id})
    %{conn: conn, admin: admin}
  end

  describe "Grading page (Index & Default Filters)" do
    test "should render all assignments by default (status 'all')", %{conn: conn} do
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
        status: :graded,
        score: 100
      )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading")

      assert html =~ "Grading Center"

      assert html =~ "johndoe"
      assert html =~ "Needs review"

      assert html =~ "janedoe"
      assert html =~ "Graded"
      assert html =~ "100 <span class=\"text-xs opacity-50 font-normal\">/ 100</span>"
    end

    test "should handle unknown accounts or blocks gracefully", %{conn: conn} do
      insert(:submission,
        account_id: Ecto.UUID.generate(),
        block_id: Ecto.UUID.generate(),
        status: :needs_review
      )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading")

      assert html =~ "Unknown"
      assert html =~ "Deleted"
    end

    test "renders rejected submissions correctly", %{conn: conn} do
      student = insert(:account, login: "cheater_student")
      block = insert(:block)

      insert(:submission,
        account_id: student.id,
        block_id: block.id,
        status: :rejected,
        score: 0
      )

      {:ok, _lv, html} = live(conn, ~p"/teaching/grading")

      assert html =~ "cheater_student"
      assert html =~ "Rejected"
      assert html =~ "badge-error badge-soft"
      assert html =~ "text-error"
    end
  end

  describe "Grading page (Filtering)" do
    test "filters by status using the select dropdown", %{conn: conn} do
      student1 = insert(:account, login: "needs_review_student")
      student2 = insert(:account, login: "graded_student")
      block = insert(:block)

      insert(:submission, account_id: student1.id, block_id: block.id, status: :needs_review)
      insert(:submission, account_id: student2.id, block_id: block.id, status: :graded)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv
        |> form("form[phx-change='update_filters']", %{"status" => "graded"})
        |> render_change()

      assert html =~ "graded_student"
      refute html =~ "needs_review_student"
    end

    test "filters by student login", %{conn: conn} do
      student1 = insert(:account, login: "alice_smith")
      student2 = insert(:account, login: "bob_jones")
      block = insert(:block)

      insert(:submission, account_id: student1.id, block_id: block.id)
      insert(:submission, account_id: student2.id, block_id: block.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv |> form("form[phx-change='update_filters']", %{"login" => "alice"}) |> render_change()

      assert html =~ "alice_smith"
      refute html =~ "bob_jones"
    end

    test "filters by cohort", %{conn: conn} do
      cohort = insert(:cohort, name: "Special Forces")
      student1 = insert(:account, login: "cohort_boy")
      student2 = insert(:account, login: "solo_boy")
      block = insert(:block)

      insert(:submission, account_id: student1.id, block_id: block.id, cohort_id: cohort.id)
      insert(:submission, account_id: student2.id, block_id: block.id)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv
        |> form("form[phx-change='update_filters']", %{"cohort_id" => cohort.id})
        |> render_change()

      assert html =~ "cohort_boy"
      refute html =~ "solo_boy"
    end

    test "filters by cheat count (has_cheats checkbox)", %{conn: conn} do
      student1 = insert(:account, login: "cheater")
      student2 = insert(:account, login: "honest")
      block = insert(:block)

      insert(:submission,
        account_id: student1.id,
        block_id: block.id,
        content: %{"cheat_count" => 3}
      )

      insert(:submission,
        account_id: student2.id,
        block_id: block.id,
        content: %{"cheat_count" => 0}
      )

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv
        |> form("form[phx-change='update_filters']", %{"has_cheats" => "true"})
        |> render_change()

      assert html =~ "cheater"
      refute html =~ "honest"
    end

    test "filters by date range", %{conn: conn} do
      student1 = insert(:account, login: "old_sub")
      student2 = insert(:account, login: "new_sub")
      block = insert(:block)

      insert(:submission,
        account_id: student1.id,
        block_id: block.id,
        inserted_at: ~U[2024-01-01 12:00:00Z]
      )

      insert(:submission,
        account_id: student2.id,
        block_id: block.id,
        inserted_at: ~U[2026-05-05 12:00:00Z]
      )

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv
        |> form("form[phx-change='update_filters']", %{
          "date_from" => "2026-05-01",
          "date_to" => "2026-05-10"
        })
        |> render_change()

      assert html =~ "new_sub"
      refute html =~ "old_sub"
    end

    test "reset filters clears all params and redirects back to base url", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teaching/grading?status=graded&login=foo&has_cheats=true")

      lv |> element("button[phx-click='reset_filters']") |> render_click()

      assert_patch(lv, "/teaching/grading")
    end

    test "filters by rejected status using the select dropdown", %{conn: conn} do
      student1 = insert(:account, login: "good_boy")
      student2 = insert(:account, login: "bad_boy")
      block = insert(:block)

      insert(:submission, account_id: student1.id, block_id: block.id, status: :graded)
      insert(:submission, account_id: student2.id, block_id: block.id, status: :rejected)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      html =
        lv
        |> form("form[phx-change='update_filters']", %{"status" => "rejected"})
        |> render_change()

      assert html =~ "bad_boy"
      refute html =~ "good_boy"
    end

    test "filters by block_id via hidden url param and displays info alert", %{conn: conn} do
      student1 = insert(:account, login: "block1_boy")
      student2 = insert(:account, login: "block2_boy")
      block1 = insert(:block, type: :text)
      block2 = insert(:block, type: :code)

      insert(:submission, account_id: student1.id, block_id: block1.id)
      insert(:submission, account_id: student2.id, block_id: block2.id)

      {:ok, lv, html} = live(conn, ~p"/teaching/grading?block_id=#{block1.id}")

      assert html =~ "block1_boy"
      refute html =~ "block2_boy"

      assert html =~ "Showing submissions filtered by a specific assignment"

      html = lv |> element("button[phx-click='clear_block_filter']") |> render_click()
      assert html =~ "block2_boy"
    end
  end

  describe "Grading page (Pagination & Sorting)" do
    test "changes page size and updates URL", %{conn: conn} do
      insert(:submission, account_id: insert(:account).id, block_id: insert(:block).id)
      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      lv
      |> form("form[phx-change='update_page_size']", %{"page_size" => "10"})
      |> render_change()

      assert_patched(
        lv,
        ~p"/teaching/grading?order_by[]=inserted_at&order_directions[]=desc&page=1&page_size=10"
      )
    end

    test "sorts by score when column header is clicked", %{conn: conn} do
      insert(:submission, account_id: insert(:account).id, block_id: insert(:block).id, score: 90)

      {:ok, lv, _html} = live(conn, ~p"/teaching/grading")

      lv
      |> element("a", "Score")
      |> render_click()

      assert_patched(
        lv,
        ~p"/teaching/grading?order_by[]=score&order_directions[]=asc&page=1&page_size=10"
      )
    end
  end

  describe "Permissions & ACL" do
    test "should redirect if user lacks grading.read permission", %{conn: conn} do
      role = insert(:role, permissions: [])
      limited_user = insert(:account, role: role)
      conn = init_test_session(conn, %{"account_id" => limited_user.id})

      assert {:error, redirect} = live(conn, ~p"/teaching/grading")

      case redirect do
        {:redirect, %{to: _path}} -> assert true
        {:live_redirect, %{to: _path}} -> assert true
        _ -> flunk("Expected a redirect due to lack of permissions")
      end
    end
  end
end
