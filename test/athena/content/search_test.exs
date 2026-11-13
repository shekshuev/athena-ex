defmodule Athena.Content.SearchTest do
  use Athena.DataCase, async: true

  import Athena.Factory
  import Ecto.Query
  alias Athena.{Content, Learning, Repo}
  alias Athena.Content.{AccessRules, CompletionRule}
  alias Athena.Learning.BlockProgress

  setup do
    user = insert(:account, role: insert(:role, permissions: []))
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)
    %{user: user, course: course, section: section}
  end

  test "literal text ranks first and safe metadata replaces content", ctx do
    exact = searchable(ctx.section, "Изучаем программирование на Elixir")
    searchable(ctx.section, "Програмирование для начинающих")
    assert {:ok, %{items: [first | _]}} = Content.search_blocks(ctx.user, "программирование")
    assert first.block_id == exact.id
    assert first.course_title == ctx.course.title
    assert first.section_title == ctx.section.title
    refute Map.has_key?(first, :content)
    refute Map.has_key?(first, :search_text)
    assert Enum.any?(first.snippet, & &1.match?)
  end

  test "fuzzy matches have context but no exact highlights", ctx do
    block =
      searchable(
        ctx.section,
        String.duplicate("Unrelated introduction. ", 100) <> "Программирование компьютеров"
      )

    assert {:ok, %{items: [item]}} = Content.search_blocks(ctx.user, "програмирование")
    assert item.block_id == block.id
    assert snippet(item) =~ "Программирование"
    refute Enum.any?(item.snippet, & &1.match?)
  end

  test "an exact match at the end of a long block is in the snippet", ctx do
    searchable(
      ctx.section,
      String.duplicate("Начало документа. ", 1000) <> "Enum.map(collection, fun)"
    )

    assert {:ok, %{items: [item]}} = Content.search_blocks(ctx.user, "Enum.map")
    assert snippet(item) =~ "Enum.map"
    assert String.length(snippet(item)) <= 240
  end

  test "a literal multiword phrase wins over unrelated fuzzy candidates", ctx do
    block = searchable(ctx.section, "Для обработки используйте бинарный поиск по массиву")
    searchable(ctx.section, "Поиск информации")
    assert {:ok, %{items: [first | _]}} = Content.search_blocks(ctx.user, "бинарный поиск")
    assert first.block_id == block.id
    assert first.exact?
  end

  test "LIKE metacharacters are literal", ctx do
    exact = searchable(ctx.section, "function foo_bar%baz\\qux")
    searchable(ctx.section, "function fooXbarYbazZqux")
    assert {:ok, %{items: items}} = Content.search_blocks(ctx.user, "foo_bar%baz\\qux")
    assert hd(items).block_id == exact.id
    assert Enum.count(items, & &1.exact?) == 1
  end

  test "invalid and punctuation-only queries are rejected", ctx do
    for query <- [nil, "", "ab", "C++", "___", "%_%", "a b c", String.duplicate("x", 201)] do
      assert {:error, :invalid_query} = Content.search_blocks(ctx.user, query)
    end
  end

  test "pending and missing texts do not appear until indexed", ctx do
    pending = searchable(ctx.section, "уникальный индекс", search_due_at: DateTime.utc_now())
    insert(:block, section: ctx.section, search_text: nil)
    assert {:ok, %{items: []}} = Content.search_blocks(ctx.user, "уникальный")
    pending |> Ecto.Changeset.change(search_due_at: nil) |> Repo.update!()
    assert {:ok, %{items: [%{block_id: id}]}} = Content.search_blocks(ctx.user, "уникальный")
    assert id == pending.id
  end

  test "other, deleted and unpublished courses stay absent", ctx do
    for attrs <- [[], [deleted_at: DateTime.utc_now(:second)], [status: :draft]] do
      course = insert(:course, attrs)
      section = insert(:section, course: course)
      searchable(section, "needle")
      if attrs != [], do: insert(:enrollment, account_id: ctx.user.id, course_id: course.id)
    end

    assert {:ok, %{items: [], has_more?: false, next_cursor: nil}} =
             Content.search_blocks(ctx.user, "needle")
  end

  test "dropped enrollments and blocked or deleted accounts cannot search", ctx do
    searchable(ctx.section, "needle")

    from(e in Athena.Learning.Enrollment, where: e.account_id == ^ctx.user.id)
    |> Repo.update_all(set: [status: :dropped])

    assert {:ok, %{items: []}} = Content.search_blocks(ctx.user, "needle")
    ctx.user |> Ecto.Changeset.change(status: :blocked) |> Repo.update!()
    assert {:error, :forbidden} = Content.search_blocks(ctx.user, "needle")

    ctx.user
    |> Ecto.Changeset.change(status: :active, deleted_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:error, :forbidden} = Content.search_blocks(ctx.user, "needle")
  end

  test "hidden, inherited and scheduled blocks obey policy", ctx do
    searchable(ctx.section, "needle", visibility: :hidden)

    searchable(ctx.section, "needle",
      visibility: :restricted,
      access_rules: %AccessRules{unlock_at: DateTime.add(DateTime.utc_now(), 3600)}
    )

    hidden = insert(:section, course: ctx.course, visibility: :hidden)
    searchable(hidden, "needle", visibility: :inherit)
    open = searchable(ctx.section, "needle", visibility: :inherit)
    assert {:ok, %{items: [%{block_id: id}]}} = Content.search_blocks(ctx.user, "needle")
    assert id == open.id
  end

  test "inaccessible top candidates cannot starve a page, including across batches", ctx do
    for _ <- 1..505, do: searchable(ctx.section, "needle", visibility: :hidden)
    ids = for _ <- 1..6, do: searchable(ctx.section, "A needlework here").id

    assert {:ok, %{items: items, has_more?: true, next_cursor: cursor}} =
             Content.search_blocks(ctx.user, "needle")

    assert length(items) == 5

    assert {:ok, %{items: rest, has_more?: false}} =
             Content.search_blocks(ctx.user, "needle", cursor: cursor)

    assert Enum.sort(Enum.map(items ++ rest, & &1.block_id)) == Enum.sort(ids)

    assert {:error, :invalid_cursor} =
             Content.search_blocks(ctx.user, "different", cursor: cursor)
  end

  test "stable tied ranks paginate without duplicate blocks", ctx do
    ids = for _ <- 1..13, do: searchable(ctx.section, "needle").id
    assert {:ok, first} = Content.search_blocks(ctx.user, "needle")
    assert {:ok, second} = Content.search_blocks(ctx.user, "needle", cursor: first.next_cursor)
    assert {:ok, third} = Content.search_blocks(ctx.user, "needle", cursor: second.next_cursor)

    assert Enum.map(first.items ++ second.items ++ third.items, & &1.block_id) ==
             Enum.sort(ids, :desc)

    refute third.has_more?
    assert third.next_cursor == nil
  end

  test "block and section waterlines reclose and resets reopen them", ctx do
    gate =
      searchable(ctx.section, "gate", order: 1, completion_rule: %CompletionRule{type: :button})

    locked = searchable(ctx.section, "needle", order: 2)

    reset =
      searchable(ctx.section, "needle",
        order: 3,
        access_rules: %AccessRules{reset_waterline: true}
      )

    later = insert(:section, course: ctx.course, order: 10)
    searchable(later, "needle")
    assert {:ok, %{items: [%{block_id: reset_id}]}} = Content.search_blocks(ctx.user, "needle")
    assert reset_id == reset.id
    assert {:error, :not_found} = Content.resolve_block_permalink(ctx.user, locked.id)
    Learning.mark_completed(ctx.user.id, gate.id)
    assert {:ok, %{items: items}} = Content.search_blocks(ctx.user, "needle")
    assert length(items) == 3
    assert {:ok, :player, _, _, _} = Content.resolve_block_permalink(ctx.user, locked.id)
    Athena.Learning.Progress.revoke_completed(Repo, ctx.user.id, gate.id)
    assert {:ok, %{items: [_]}} = Content.search_blocks(ctx.user, "needle")
    assert {:error, :not_found} = Content.resolve_block_permalink(ctx.user, locked.id)
  end

  test "finished submissions unlock read-only search without healing progress", ctx do
    gate =
      searchable(ctx.section, "gate", order: 1, completion_rule: %CompletionRule{type: :submit})

    target = searchable(ctx.section, "needle", order: 2)
    insert(:submission, block_id: gate.id, account_id: ctx.user.id, status: :accepted)
    assert {:ok, %{items: [%{block_id: id}]}} = Content.search_blocks(ctx.user, "needle")
    assert id == target.id
    refute Repo.exists?(from p in BlockProgress, where: p.block_id == ^gate.id)
    lessons = Content.list_linear_lessons(ctx.course.id, ctx.user)
    Learning.accessible_section_ids(ctx.user, ctx.course.id, lessons, [])
    assert Repo.exists?(from p in BlockProgress, where: p.block_id == ^gate.id)
  end

  test "local PostgreSQL thresholds are restored", ctx do
    searchable(ctx.section, "needle")
    Repo.query!("SELECT set_config('pg_trgm.word_similarity_threshold', '0.85', true)")
    before = Repo.query!("SHOW pg_trgm.word_similarity_threshold").rows
    timeout = Repo.query!("SHOW statement_timeout").rows
    assert {:ok, _} = Content.search_blocks(ctx.user, "needle")
    assert Repo.query!("SHOW pg_trgm.word_similarity_threshold").rows == before
    assert Repo.query!("SHOW statement_timeout").rows == timeout
  end

  test "query count is independent of the number of results in one course", ctx do
    searchable(ctx.section, "needle")
    handler = {__MODULE__, make_ref()}
    owner = self()

    :telemetry.attach(
      handler,
      [:athena, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner, do: send(owner, {:search_sql, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} = Content.search_blocks(ctx.user, "needle")
    first = collect_queries()
    for _ <- 1..30, do: searchable(ctx.section, "needle")
    _ = collect_queries()
    assert {:ok, _} = Content.search_blocks(ctx.user, "needle")
    second = collect_queries()
    assert length(first) == length(second)
    assert length(second) < 20

    for sql <- second,
        String.starts_with?(sql, "SELECT"),
        String.contains?(sql, ~s(FROM "blocks")) do
      [select | _] = String.split(sql, " FROM ", parts: 2)
      refute select =~ ~s(."content")
    end
  end

  defp collect_queries(acc \\ []) do
    receive do
      {:search_sql, sql} -> collect_queries([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp searchable(section, text, opts \\ []),
    do: insert(:block, Keyword.merge([section: section, search_text: text], opts))

  defp snippet(item), do: Enum.map_join(item.snippet, & &1.text)
end
