defmodule Athena.Content.Search do
  @moduledoc """
  Student search over current, safe block text, with the player's access rules.

  Queries contain 3..200 characters and at least three consecutive letters or
  digits. Literal phrases rank before fuzzy phrases (word similarity > 0.6).
  Pages contain five results. Pass `next_cursor` back as `:cursor`; cursors
  are positions, never authorization. Access is recalculated on every call.

  The candidate query and access/presentation stages are separate so future
  candidate sources can share the same authorization and result contract.
  """
  import Ecto.Query

  alias Athena.{Learning, Repo}
  alias Athena.Content.{Block, Course, Section, SearchSnippet}
  alias Athena.Identity.Account
  alias Athena.Learning.{Enrollment, CohortMembership}

  @page_size 5
  @batch_size 500
  @budget_ms 5_000

  @doc "Returns safe result metadata, snippet segments and a continuation cursor."
  def search(user, input, opts \\ []) do
    with {:ok, query} <- normalize(input),
         {:ok, cursor} <- validate_cursor(Keyword.get(opts, :cursor), query),
         %Account{status: :active, deleted_at: nil} = account <- Repo.get(Account, user.id) do
      deadline = System.monotonic_time(:millisecond) + @budget_ms

      Repo.transaction(
        fn ->
          # Restore explicitly as well: callers may already be in a transaction.
          %{rows: [[threshold, timeout]]} =
            Repo.query!(
              "SELECT current_setting('pg_trgm.word_similarity_threshold'), current_setting('statement_timeout')"
            )

          Repo.query!("SELECT set_config('pg_trgm.word_similarity_threshold', '0.6', true)")
          result = gather(account, query, cursor, %{}, [], deadline)

          Repo.query!(
            "SELECT set_config('pg_trgm.word_similarity_threshold', $1, true), set_config('statement_timeout', $2, true)",
            [threshold, timeout]
          )

          result
        end,
        timeout: @budget_ms + 1_000
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :query_canceled} -> {:error, :timeout}
        _ -> {:error, :unavailable}
      end

    _error in DBConnection.ConnectionError ->
      {:error, :unavailable}
  end

  defp normalize(input) when is_binary(input) do
    if byte_size(input) > 800 or not String.valid?(input) do
      {:error, :invalid_query}
    else
      query = String.trim(input)

      if String.length(query) in 3..200 and Regex.match?(~r/[\p{L}\p{N}]{3}/u, query),
        do: {:ok, query},
        else: {:error, :invalid_query}
    end
  end

  defp normalize(_), do: {:error, :invalid_query}

  defp validate_cursor(nil, _query), do: {:ok, nil}

  defp validate_cursor(%{query: query, block_id: id, exact?: exact?, rank: rank} = cursor, query)
       when is_boolean(exact?) and is_float(rank) and rank >= 0.0 and rank <= 1.0 do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, cursor}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp validate_cursor(_, _), do: {:error, :invalid_cursor}

  defp gather(user, query, cursor, access, found, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: Repo.rollback(:timeout)

    Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
      Integer.to_string(max(remaining, 1))
    ])

    candidates = Repo.all(candidates(user.id, query, cursor))

    {results, access} =
      resolve_candidates(
        candidates,
        access,
        user,
        query,
        @page_size + 1 - length(found),
        deadline
      )

    found = found ++ results
    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:timeout)

    cond do
      length(found) > @page_size -> page(found, query, true)
      length(candidates) < @batch_size -> page(found, query, false)
      true -> gather(user, query, position(List.last(candidates), query), access, found, deadline)
    end
  end

  defp candidates(account_id, query, cursor) do
    memberships =
      from m in CohortMembership, where: m.account_id == ^account_id, select: m.cohort_id

    courses =
      from e in Enrollment,
        where: e.status != :dropped,
        where: e.account_id == ^account_id or e.cohort_id in subquery(memberships),
        select: e.course_id

    literal = "%" <> escape_like(query) <> "%"

    ranked =
      from b in Block,
        join: s in Section,
        on: s.id == b.section_id,
        join: c in Course,
        on: c.id == s.course_id,
        where: c.id in subquery(courses) and c.status == :published and is_nil(c.deleted_at),
        where: not is_nil(b.search_text) and is_nil(b.search_due_at),
        where: fragment("? <% ?", ^query, b.search_text) or ilike(b.search_text, ^literal),
        select: %{
          block_id: b.id,
          course_id: c.id,
          course_title: c.title,
          section_id: s.id,
          section_title: s.title,
          exact?: ilike(b.search_text, ^literal),
          rank: fragment("word_similarity(?, ?)", ^query, b.search_text)
        }

    ranked = from(r in subquery(ranked))

    ranked =
      if cursor do
        from r in ranked,
          where:
            fragment(
              "(?, ?, ?) < (?, ?, ?)",
              r.exact?,
              r.rank,
              r.block_id,
              ^cursor.exact?,
              ^cursor.rank,
              type(^cursor.block_id, :binary_id)
            )
      else
        ranked
      end

    from r in ranked,
      order_by: [desc: r.exact?, desc: r.rank, desc: r.block_id],
      limit: @batch_size
  end

  defp escape_like(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp resolve_candidates(candidates, access, user, query, limit, deadline) do
    {allowed, remaining, access} = authorize(candidates, access, user, limit, [], deadline)
    texts = current_texts(Enum.map(allowed, & &1.block_id), limit)

    results =
      for candidate <- allowed,
          text = Map.get(texts, candidate.block_id),
          is_binary(text),
          do: present(candidate, text, query)

    if length(results) < limit and remaining != [] do
      {more, access} =
        resolve_candidates(remaining, access, user, query, limit - length(results), deadline)

      {results ++ more, access}
    else
      {results, access}
    end
  end

  defp authorize(remaining, access, _user, 0, allowed, _deadline),
    do: {Enum.reverse(allowed), remaining, access}

  defp authorize([], access, _user, _limit, allowed, _deadline),
    do: {Enum.reverse(allowed), [], access}

  defp authorize([candidate | remaining], access, user, limit, allowed, deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: Repo.rollback(:timeout)

    access =
      Map.put_new_lazy(access, candidate.course_id, fn ->
        Learning.course_block_access(user, candidate.course_id)
      end)

    if Map.has_key?(Map.fetch!(access, candidate.course_id), candidate.block_id) do
      authorize(remaining, access, user, limit - 1, [candidate | allowed], deadline)
    else
      authorize(remaining, access, user, limit, allowed, deadline)
    end
  end

  defp current_texts([], _limit), do: %{}

  defp current_texts(ids, limit) do
    from(b in Block,
      where: b.id in ^ids and is_nil(b.search_due_at) and not is_nil(b.search_text),
      order_by: fragment("array_position(?, ?)", type(^ids, {:array, :binary_id}), b.id),
      limit: ^limit,
      select: {b.id, b.search_text}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp present(candidate, text, query) do
    Map.merge(candidate, SearchSnippet.build(text, query, candidate.exact?))
  end

  defp page(found, query, has_more?) do
    items = Enum.take(found, @page_size)

    %{
      items: items,
      has_more?: has_more?,
      next_cursor: if(has_more?, do: position(List.last(items), query))
    }
  end

  defp position(item, query),
    do: %{query: query, block_id: item.block_id, exact?: item.exact?, rank: item.rank}
end
