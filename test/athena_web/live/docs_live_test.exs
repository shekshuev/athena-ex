defmodule AthenaWeb.DocsLiveTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  alias AthenaWeb.Docs

  defp sign_in(conn, permissions) do
    account = insert(:account, role: insert(:role, permissions: permissions))
    init_test_session(conn, %{"account_id" => account.id})
  end

  defp first_page, do: "en" |> Docs.tree() |> hd() |> Map.fetch!(:pages) |> hd()

  test "without docs.read the documentation is closed", %{conn: conn} do
    conn = sign_in(conn, ["courses.read"])
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/docs")
  end

  test "with docs.read: the home page lists the sections", %{conn: conn} do
    conn = sign_in(conn, ["docs.read"])
    {:ok, lv, _html} = live(conn, ~p"/docs")

    assert has_element?(lv, "#docs-home")
    section = "en" |> Docs.tree() |> hd() |> Map.fetch!(:section)
    assert lv |> element("#docs-home") |> render() =~ section.title
  end

  test "admins see it without the permission", %{conn: conn} do
    conn = sign_in(conn, ["admin"])
    assert {:ok, _lv, _html} = live(conn, ~p"/docs")
  end

  test "a page shows its title, its place in the contents and the stub notice", %{conn: conn} do
    conn = sign_in(conn, ["docs.read"])
    page = first_page()
    {:ok, lv, _html} = live(conn, "/docs/" <> page.path)

    assert lv |> element("#docs-title") |> render() =~ page.title
    assert has_element?(lv, "#docs-nav-#{String.replace(page.path, "/", "-")}.is-active")
    assert has_element?(lv, "#docs-stub") == page.stub?
    refute has_element?(lv, "#docs-fallback")
  end

  test "the contents filter narrows the navigation", %{conn: conn} do
    conn = sign_in(conn, ["docs.read"])
    page = first_page()
    {:ok, lv, _html} = live(conn, ~p"/docs")

    lv |> element("form[phx-change=filter]") |> render_change(%{"query" => "zzzz-nothing"})
    refute has_element?(lv, "#docs-nav-#{String.replace(page.path, "/", "-")}")

    lv |> element("form[phx-change=filter]") |> render_change(%{"query" => page.title})
    assert has_element?(lv, "#docs-nav-#{String.replace(page.path, "/", "-")}")
  end

  test "an unknown page goes back to the documentation home", %{conn: conn} do
    conn = sign_in(conn, ["docs.read"])
    assert {:error, {:live_redirect, %{to: "/docs"}}} = live(conn, ~p"/docs/no/such-page")
  end

  test "the sidebar shows Documentation only with docs.read", %{conn: conn} do
    {:ok, lv, _html} = conn |> sign_in(["docs.read"]) |> live(~p"/dashboard")
    assert has_element?(lv, "#sidebar-docs")

    {:ok, lv, _html} = build_conn() |> sign_in(["courses.read"]) |> live(~p"/dashboard")
    refute has_element?(lv, "#sidebar-docs")
  end
end
