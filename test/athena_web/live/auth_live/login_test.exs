defmodule AthenaWeb.AuthLive.LoginTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  import Athena.Factory

  describe "Login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/auth/login")

      assert html =~ "Welcome Back"
      assert html =~ "Log in"
      assert html =~ "Login"
      assert html =~ "Password"
    end

    test "redirects if user is already logged in", %{conn: conn} do
      account = insert(:account)

      conn = init_test_session(conn, %{"account_id" => account.id})

      assert {:error, redirect} = live(conn, ~p"/auth/login")
      assert {:redirect, %{to: "/dashboard"}} = redirect
    end

    test "shows validation errors on change (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/auth/login")

      html =
        lv
        |> form("#user", %{
          "user" => %{"login" => "a", "password" => "123"}
        })
        |> render_change()

      assert html =~ "should be between 3 and 50 characters"
      assert html =~ "must be at least 8 characters long"
    end

    test "shows invalid credentials error on submit if user does not exist", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/auth/login")

      html =
        lv
        |> form("#user", %{
          "user" => %{"login" => "valid_login", "password" => "Password123!"}
        })
        |> render_submit()

      assert html =~ "Invalid login or password"
    end

    test "sets trigger_action to true on valid submit", %{conn: conn} do
      insert(:account, login: "test_user")

      {:ok, lv, _html} = live(conn, ~p"/auth/login")

      html =
        lv
        |> form("#user", %{
          "user" => %{"login" => "test_user", "password" => "Password123!"}
        })
        |> render_submit()

      assert html =~ "phx-trigger-action"
    end
  end
end
