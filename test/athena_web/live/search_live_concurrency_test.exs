defmodule AthenaWeb.SearchLiveConcurrencyTest do
  use ExUnit.Case, async: false
  import Athena.Factory
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Athena.Repo
  alias Ecto.Adapters.SQL.Sandbox
  @endpoint AthenaWeb.Endpoint

  # Real commits let a cancelled task release its own database transaction.
  # Killing a borrower inside SQL Sandbox would roll back the fixture owner.
  setup do
    Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    role = insert(:role, permissions: [])
    user = insert(:account, role: role)
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)
    insert(:block, section: section)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(course)
        Repo.delete!(user)
        Repo.delete!(role)
      end)
    end)

    conn = build_conn() |> init_test_session(%{"account_id" => user.id})
    {:ok, player, _} = live(conn, "/learn/courses/#{course.id}/play/#{section.id}")
    %{user: user, section: section, search: find_live_child(player, "global-search")}
  end

  test "a newer query cancels slow work and keeps only its own results", ctx do
    slow = "slow#{System.unique_integer([:positive])}"
    fast = "fast#{System.unique_integer([:positive])}"
    old = insert(:block, section: ctx.section, search_text: slow)
    fresh = insert(:block, section: ctx.section, search_text: fast)
    block_search(slow)
    open(ctx.search)
    search(ctx.search, slow)
    assert_receive {:search_waiting, task}, 5_000
    ref = Process.monitor(task)
    assert has_element?(ctx.search, "#global-search-loading")
    search(ctx.search, fast)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 5_000
    render_async(ctx.search, 5_000)
    assert has_element?(ctx.search, "#global-search-result-#{fresh.id}")
    refute has_element?(ctx.search, "#global-search-result-#{old.id}")
  end

  test "closing while a query is running cancels it and reopening starts empty", ctx do
    query = "slow#{System.unique_integer([:positive])}"
    insert(:block, section: ctx.section, search_text: query)
    block_search(query)
    open(ctx.search)
    search(ctx.search, query)
    assert_receive {:search_waiting, task}, 5_000
    ref = Process.monitor(task)
    ctx.search |> element("#global-search-close") |> render_click()
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 5_000
    assert has_element?(ctx.search, "#global-search-dialog[data-open=false]")
    open(ctx.search)
    assert has_element?(ctx.search, "#global-search-input[value='']")
    assert has_element?(ctx.search, "#global-search-hint")
    refute has_element?(ctx.search, "#global-search-results > a")
  end

  defp open(view), do: view |> element("#global-search-open") |> render_click()

  defp search(view, query),
    do: view |> form("#global-search-form", search: %{query: query}) |> render_change()

  defp block_search(query) do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:athena, :repo, :query],
      fn _, _, meta, _ ->
        if String.contains?(meta.query, "word_similarity(") && query in (meta.params || []) do
          send(owner, {:search_waiting, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> :ok
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
