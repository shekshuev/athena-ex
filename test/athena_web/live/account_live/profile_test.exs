defmodule AthenaWeb.AccountLive.ProfileTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  describe "Profile page" do
    test "renders the profile tab by default with the account's data", %{conn: conn} do
      account = insert(:account)
      insert(:profile, owner: account, first_name: "Ada", last_name: "Lovelace")

      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, lv, html} = live(conn, ~p"/me")

      assert html =~ "My Account"
      assert has_element?(lv, "#profile-form")
    end

    test "shows the account's current name in the personal info form", %{conn: conn} do
      account = insert(:account)
      insert(:profile, owner: account, first_name: "Ada", last_name: "Lovelace")

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me")

      assert lv
             |> element("#profile-form input[name='profile[first_name]']")
             |> render() =~ "Ada"
    end

    test "switches to the achievements tab via patch", %{conn: conn} do
      account = insert(:account)
      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, lv, _html} = live(conn, ~p"/me")

      html =
        lv
        |> element("#achievements-tab-link")
        |> render_click()

      assert html =~ "Achievements"
      refute has_element?(lv, "#profile-form")
    end

    test "updates the profile with valid data", %{conn: conn} do
      account = insert(:account)
      insert(:profile, owner: account, first_name: "Ada", last_name: "Lovelace")

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me")

      lv
      |> form("#profile-form", %{
        "profile" => %{"first_name" => "Grace", "last_name" => "Hopper"}
      })
      |> render_submit()

      profile = Athena.Repo.get_by!(Athena.Identity.Profile, owner_id: account.id)
      assert profile.first_name == "Grace"
      assert profile.last_name == "Hopper"
    end

    test "shows a validation error when clearing a required field", %{conn: conn} do
      account = insert(:account)
      insert(:profile, owner: account)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me")

      html =
        lv
        |> form("#profile-form", %{"profile" => %{"first_name" => ""}})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "changes the password with a correct current password", %{conn: conn} do
      account = insert(:account)
      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, lv, _html} = live(conn, ~p"/me")

      lv
      |> form("#password-form", %{
        "password" => %{
          "current_password" => "Password123!",
          "password" => "NewStrongPass1!",
          "password_confirmation" => "NewStrongPass1!"
        }
      })
      |> render_submit()

      updated = Athena.Repo.get!(Athena.Identity.Account, account.id)
      assert updated.password_hash != account.password_hash
    end

    test "shows an error when the current password is wrong", %{conn: conn} do
      account = insert(:account)
      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, lv, _html} = live(conn, ~p"/me")

      html =
        lv
        |> form("#password-form", %{
          "password" => %{
            "current_password" => "WrongPassword1!",
            "password" => "NewStrongPass1!",
            "password_confirmation" => "NewStrongPass1!"
          }
        })
        |> render_submit()

      assert html =~ "is incorrect"

      unchanged = Athena.Repo.get!(Athena.Identity.Account, account.id)
      assert unchanged.password_hash == account.password_hash
    end
  end

  describe "Achievements tab" do
    test "shows the account's XP total and level", %{conn: conn} do
      account = insert(:account)
      block = insert(:block, type: :code)

      Athena.Gamification.XpLedger.record_activity(%{
        account_id: account.id,
        block_id: block.id,
        block_type: :code
      })

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me?tab=achievements")

      html = render(lv)
      assert html =~ "Level 1"
      assert html =~ "15 XP"
    end

    test "shows the account's current streak", %{conn: conn} do
      account = insert(:account)

      insert(:account_stats,
        account_id: account.id,
        current_streak_weeks: 3,
        longest_streak_weeks: 5
      )

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me?tab=achievements")

      html = render(lv)
      assert html =~ "3 week streak"
      assert html =~ "Best: 5 weeks"
    end

    test "shows earned badges", %{conn: conn} do
      account = insert(:account)
      admin = insert(:account, role: insert(:role, permissions: ["gamification.create"]))

      {:ok, badge} =
        Athena.Gamification.create_badge(admin, %{
          "key" => "first-steps",
          "title" => "First Steps",
          "rule" => %{"fact" => "total_xp", "op" => "gte", "value" => 0}
        })

      Athena.Gamification.Badges.evaluate_for_account(account.id)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me?tab=achievements")

      html = render(lv)
      assert html =~ badge.title
    end

    test "shows an empty state with no badges yet", %{conn: conn} do
      account = insert(:account)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me?tab=achievements")

      assert render(lv) =~ "No badges yet"
    end

    test "shows an empty state when not in an academic cohort", %{conn: conn} do
      account = insert(:account)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me?tab=achievements")

      assert render(lv) =~ "Join an academic cohort"
    end

    test "shows the weekly league standings for the account's cohort", %{conn: conn} do
      account = insert(:account)
      cohort = insert(:cohort, type: :academic)
      course = insert(:course)

      insert(:enrollment, cohort_id: cohort.id, course_id: course.id)
      insert(:cohort_membership, account_id: account.id, cohort_id: cohort.id)

      block = insert(:block, type: :code)

      Athena.Gamification.XpLedger.record_activity(%{
        account_id: account.id,
        block_id: block.id,
        block_type: :code
      })

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me?tab=achievements")

      html = render(lv)
      assert html =~ "Weekly League"
      assert html =~ cohort.name
      assert html =~ "You"
    end

    test "toggles league visibility", %{conn: conn} do
      account = insert(:account)

      conn = init_test_session(conn, %{"account_id" => account.id})
      {:ok, lv, _html} = live(conn, ~p"/me?tab=achievements")

      lv |> element("input[phx-click='toggle_league_visibility']") |> render_click()

      profile = Athena.Repo.get_by!(Athena.Identity.Profile, owner_id: account.id)
      assert profile.metadata["show_in_league"] == false
    end
  end
end
