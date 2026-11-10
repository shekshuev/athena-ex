defmodule AthenaWeb.SessionControllerTest do
  use AthenaWeb.ConnCase, async: true

  import Athena.Factory
  import Phoenix.LiveViewTest

  for kind <- ["blocks", "sections"], suffix <- ["", "/edit"] do
    @kind kind
    @suffix suffix
    test "returns to a #{@kind}#{@suffix} permalink after login", %{conn: conn} do
      account = insert(:account)
      course = insert(:course, owner_id: account.id)
      insert(:enrollment, account_id: account.id, course_id: course.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)
      id = if @kind == "blocks", do: block.id, else: section.id
      path = "/go/#{@kind}/#{id}#{@suffix}?source=shared"

      conn = get(conn, path)
      assert redirected_to(conn) == "/auth/login"

      conn = conn |> recycle() |> get(~p"/auth/login")
      assert html_response(conn, 200)

      conn =
        conn
        |> recycle()
        |> post(~p"/auth/log_in", user: %{login: account.login, password: "Password123!"})

      assert redirected_to(conn) == path
      assert get_session(conn, :account_id) == account.id
      refute get_session(conn, :permalink_return_to)

      conn = conn |> recycle() |> get(path)

      target =
        case {@kind, @suffix} do
          {"blocks", "/edit"} ->
            ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}/blocks/#{block.id}"

          {"sections", "/edit"} ->
            ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}"

          {"blocks", ""} ->
            ~p"/learn/courses/#{course.id}/play/#{section.id}?block=#{block.id}"

          {"sections", ""} ->
            ~p"/learn/courses/#{course.id}/play/#{section.id}"
        end

      assert redirected_to(conn) == target
    end
  end

  test "failed login preserves the permalink for a retry", %{conn: conn} do
    account = insert(:account)
    path = ~p"/go/blocks/#{Ecto.UUID.generate()}"
    conn = get(conn, path)

    conn =
      conn
      |> recycle()
      |> post(~p"/auth/log_in", user: %{login: account.login, password: "WrongPassword123!"})

    assert redirected_to(conn) == "/auth/login"
    assert get_session(conn, :permalink_return_to) == path

    conn =
      conn
      |> recycle()
      |> post(~p"/auth/log_in", user: %{login: account.login, password: "Password123!"})

    assert redirected_to(conn) == path
  end

  test "ordinary login still opens the dashboard", %{conn: conn} do
    account = insert(:account)

    conn =
      post(conn, ~p"/auth/log_in", user: %{login: account.login, password: "Password123!"})

    assert redirected_to(conn) == "/dashboard"
  end

  test "preserves the permalink through a required password change", %{conn: conn} do
    account = insert(:account, must_change_password: true)
    course = insert(:course, owner_id: account.id)
    section = insert(:section, course: course)
    path = ~p"/go/sections/#{section.id}/edit"
    conn = get(conn, path)

    conn =
      conn
      |> recycle()
      |> post(~p"/auth/log_in", user: %{login: account.login, password: "Password123!"})

    assert redirected_to(conn) == path
    conn = conn |> recycle() |> get(path)
    assert redirected_to(conn) == "/force-password-change"

    {:ok, view, _html} = live(recycle(conn), ~p"/force-password-change")

    view
    |> form("#password_change_form", %{
      user: %{password: "NewPassword123!", password_confirmation: "NewPassword123!"}
    })
    |> render_submit()

    assert_redirect(view, path)

    conn = conn |> recycle() |> get(path)

    assert redirected_to(conn) ==
             ~p"/studio/courses/#{course.id}/builder/sections/#{section.id}"

    refute get_session(conn, :permalink_return_to)
  end
end
