defmodule AthenaWeb.AuthLive.ForcePasswordChangeTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  describe "Force Password Change page" do
    test "redirects to dashboard if user does not need to change password", %{conn: conn} do
      account = insert(:account, must_change_password: false)

      conn = init_test_session(conn, %{"account_id" => account.id})

      assert {:error, redirect} = live(conn, ~p"/force-password-change")
      assert {:redirect, %{to: "/dashboard"}} = redirect
    end

    test "renders page if user must change password", %{conn: conn} do
      account = insert(:account, must_change_password: true)

      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, _lv, html} = live(conn, ~p"/force-password-change")

      assert html =~ "Security Update Required"
      assert html =~ "New Password"
      assert html =~ "Confirm New Password"
    end

    test "shows validation errors on change for weak password (phx-change)", %{conn: conn} do
      account = insert(:account, must_change_password: true)
      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, lv, _html} = live(conn, ~p"/force-password-change")

      html =
        lv
        |> form("#password_change_form", %{
          "user" => %{
            "password" => "weak",
            "password_confirmation" => "weak"
          }
        })
        |> render_change()

      assert html =~ "must be at least 8 characters long"
    end

    test "shows validation errors on change for mismatched confirmation (phx-change)", %{
      conn: conn
    } do
      account = insert(:account, must_change_password: true)
      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, lv, _html} = live(conn, ~p"/force-password-change")

      html =
        lv
        |> form("#password_change_form", %{
          "user" => %{
            "password" => "StrongPassword123!",
            "password_confirmation" => "WrongPassword123!"
          }
        })
        |> render_change()

      assert html =~ "does not match password"
    end

    test "changes password, resets flag, and redirects on valid submit", %{conn: conn} do
      account = insert(:account, must_change_password: true)
      conn = init_test_session(conn, %{"account_id" => account.id})

      {:ok, lv, _html} = live(conn, ~p"/force-password-change")

      lv
      |> form("#password_change_form", %{
        "user" => %{
          "password" => "NewStrongPassword123!",
          "password_confirmation" => "NewStrongPassword123!"
        }
      })
      |> render_submit()
      |> follow_redirect(conn, "/dashboard")

      updated_account = Athena.Repo.get!(Athena.Identity.Account, account.id)
      refute updated_account.must_change_password
    end
  end
end
