defmodule AthenaWeb.SearchLiveTest do
  use AthenaWeb.ConnCase, async: true

  import Athena.Factory
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = insert(:account, role: insert(:role, permissions: []))
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)
    insert(:block, section: section)
    conn = init_test_session(conn, %{"account_id" => user.id})
    {:ok, player, _} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")
    search = find_live_child(player, "global-search")
    %{conn: conn, user: user, course: course, section: section, player: player, search: search}
  end

  test "the layout opens and closes an isolated palette without replacing the player", ctx do
    assert has_element?(ctx.player, "header #global-search-open")
    assert has_element?(ctx.search, "#global-search-dialog[data-open=false]")
    open(ctx.search)
    assert has_element?(ctx.search, "#global-search-dialog[data-open=true]")
    assert has_element?(ctx.search, "#global-search-hint")
    ctx.search |> element("#global-search-close") |> render_click()
    assert has_element?(ctx.search, "#global-search-dialog[data-open=false]")
    assert find_live_child(ctx.player, "global-search").pid == ctx.search.pid
    assert has_element?(ctx.player, "#engagement-tracker")
  end

  test "searches across courses with safe highlighted links and no closed blocks", ctx do
    other = insert(:course)
    insert(:enrollment, account_id: ctx.user.id, course_id: other.id)
    section = insert(:section, course: other)
    found = insert(:block, section: section, search_text: "Работа с Enum.map в Elixir")
    hidden = insert(:block, section: section, search_text: "Enum.map", visibility: :hidden)
    open(ctx.search)
    search(ctx.search, "Enum.map")
    render_async(ctx.search, 5_000)

    assert has_element?(
             ctx.search,
             "#global-search-result-#{found.id}[href='/go/blocks/#{found.id}']"
           )

    assert has_element?(ctx.search, "#global-search-result-#{found.id} mark", "Enum.map")
    refute has_element?(ctx.search, "#global-search-result-#{hidden.id}")
    refute has_element?(ctx.search, "#global-search-empty")
  end

  test "short, blank and punctuation queries show guidance; a valid missing query shows empty",
       ctx do
    open(ctx.search)

    for query <- ["", "ab", "___"] do
      search(ctx.search, query)
      assert has_element?(ctx.search, "#global-search-hint")
      refute has_element?(ctx.search, "#global-search-loading")
    end

    search(ctx.search, "absentmaterial")
    render_async(ctx.search, 5_000)
    assert has_element?(ctx.search, "#global-search-empty")
    refute has_element?(ctx.search, "#global-search-error")
  end

  test "show more appends results and changing the query resets pagination", ctx do
    blocks = for n <- 1..7, do: insert(:block, section: ctx.section, search_text: "needle #{n}")
    different = insert(:block, section: ctx.section, search_text: "differenttopic")
    open(ctx.search)
    search(ctx.search, "needle")
    render_async(ctx.search, 5_000)
    assert has_element?(ctx.search, "#global-search-results > a:nth-child(5)")
    refute has_element?(ctx.search, "#global-search-results > a:nth-child(6)")
    ctx.search |> element("#global-search-more") |> render_click()
    render_async(ctx.search, 5_000)
    assert has_element?(ctx.search, "#global-search-results > a:nth-child(7)")
    refute has_element?(ctx.search, "#global-search-more")
    for block <- blocks, do: assert(has_element?(ctx.search, "#global-search-result-#{block.id}"))
    search(ctx.search, "differenttopic")
    render_async(ctx.search, 5_000)
    assert has_element?(ctx.search, "#global-search-result-#{different.id}")
    refute has_element?(ctx.search, "#global-search-results > a:nth-child(2)")
  end

  test "the search affordance is scoped to the player", ctx do
    {:ok, dashboard, _} = live(ctx.conn, ~p"/dashboard")
    refute has_element?(dashboard, "#global-search-open")
  end

  defp open(view), do: view |> element("#global-search-open") |> render_click()

  defp search(view, query),
    do: view |> form("#global-search-form", search: %{query: query}) |> render_change()
end
