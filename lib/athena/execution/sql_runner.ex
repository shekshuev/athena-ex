defmodule Athena.Execution.SqlRunner do
  @moduledoc """
  Low-level runner for executing SQL in an isolated, ephemeral PostgreSQL database.
  Handles database & role lifecycle:
    create restricted role -> create db owned by role -> run setup & student code as restricted user -> cleanup.
  """
  require Logger

  alias Athena.Execution.SqlValue

  # Fixed PRNG seed, re-applied before every query so that `random()` /
  # `ORDER BY RANDOM()` yields the same values for the reference solution
  # and the student's query (the session PRNG is otherwise consumed by
  # whichever query runs first).
  @seed 0.42

  @behaviour Athena.Execution.Database.Adapter

  @doc """
  Runs a callback function within an ephemeral sandbox database under an unprivileged user role.
  Creates the database directly owned by the restricted role, then executes both setup_sql
  and the student callback under that restricted connection.
  Always drops the sandbox database and temporary role upon completion.
  """
  @spec execute_in_sandbox(integer(), String.t() | nil, (pid() -> result)) ::
          {:ok, result} | {:error, {:setup_error, String.t()} | {:system_error, any()}}
        when result: any()
  @impl true
  def execute_in_sandbox(box_id, setup_sql, callback) do
    token = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    db_name = "athena_sandbox_#{box_id}_#{token}"
    role_name = "athena_user_#{token}"
    role_pass = :crypto.strong_rand_bytes(24) |> Base.encode16(case: :lower)

    case connect_admin() do
      {:ok, admin_conn} ->
        try do
          with :ok <- create_role(admin_conn, role_name, role_pass),
               :ok <- create_db(admin_conn, db_name, role_name),
               {:ok, user_conn} <- connect_user(db_name, role_name, role_pass) do
            try do
              reseed(user_conn)

              case execute_setup(user_conn, setup_sql) do
                :ok ->
                  {:ok, callback.(user_conn)}

                {:error, msg} ->
                  {:error, {:setup_error, msg}}
              end
            after
              GenServer.stop(user_conn)
            end
          else
            {:error, reason} -> {:error, {:system_error, reason}}
          end
        after
          drop_db(admin_conn, db_name)
          drop_role(admin_conn, role_name)
          GenServer.stop(admin_conn)
        end

      {:error, reason} ->
        Logger.error("Failed to connect admin to SQL sandbox: #{inspect(reason)}")
        {:error, {:system_error, reason}}
    end
  end

  @doc """
  Executes a single SQL query with a specified time limit (in seconds).

  The session PRNG is reset to a fixed seed first, so queries using `random()`
  are reproducible: running the same query twice returns the same rows.

  Results are fetched in `:stream_max_rows` chunks and bounded by
  `:max_result_rows`, `:max_result_bytes`, `:max_row_bytes` and `:max_cell_bytes`
  in this module's application configuration. Byte limits measure JSON after
  `SqlValue` conversion. Exceeding a limit rolls back the query and returns
  `{:error, {:result_limit_exceeded, message}}`, without a partial result.

  Byte checks run after Postgrex decodes a chunk; they do not bound PostgreSQL
  execution memory or prevent allocation of a single oversized value.
  """
  @spec query(pid(), String.t(), float()) ::
          {:ok, Postgrex.Result.t()}
          | {:error,
             :timeout
             | {:result_limit_exceeded, String.t()}
             | {:sql_error, String.t()}
             | {:system_error, any()}}
  @impl true
  def query(conn, sql, time_limit_sec) do
    statement_timeout_ms = trunc((time_limit_sec || 2.0) * 1000)
    reseed(conn)
    bounded_query(conn, sql, statement_timeout_ms)
  end

  defp bounded_query(conn, sql, statement_timeout_ms) do
    client_timeout_ms = statement_timeout_ms + 2_000
    limits = Application.fetch_env!(:athena, __MODULE__)
    deadline = System.monotonic_time(:millisecond) + statement_timeout_ms

    case Postgrex.query(conn, "SET statement_timeout = #{statement_timeout_ms}", []) do
      {:ok, _} ->
        Postgrex.transaction(
          conn,
          &collect_result(&1, sql, limits, deadline, client_timeout_ms),
          timeout: client_timeout_ms
        )

      {:error, error} ->
        query_error(error)
    end
  rescue
    error in Postgrex.Error -> query_error(error)
    error in DBConnection.ConnectionError -> {:error, {:system_error, error}}
  end

  defp collect_result(conn, sql, limits, deadline, timeout) do
    initial = %{result: nil, rows: [], count: 0, bytes: 2}

    state =
      conn
      |> Postgrex.stream(sql, [],
        max_rows: Keyword.fetch!(limits, :stream_max_rows),
        timeout: timeout
      )
      |> Enum.reduce(initial, &collect_chunk(&1, &2, conn, limits, deadline))

    # DML without RETURNING reports affected rows, not returned rows.
    result = state.result
    rows = if is_nil(result.rows), do: nil, else: Enum.reverse(state.rows)
    num_rows = if is_nil(result.columns), do: result.num_rows, else: state.count
    %{result | rows: rows, num_rows: num_rows}
  end

  defp collect_chunk(chunk, state, conn, limits, deadline) do
    check_deadline!(conn, deadline)

    Enum.reduce(
      chunk.rows || [],
      %{state | result: chunk},
      &collect_row(&1, &2, conn, limits, deadline)
    )
  end

  defp collect_row(row, state, conn, limits, deadline) do
    check_deadline!(conn, deadline)
    count = state.count + 1
    check_limit!(conn, count, limits, :max_result_rows, "rows")

    cells = Enum.map(row, &SqlValue.to_cell/1)

    Enum.each(cells, fn cell ->
      check_limit!(conn, json_size(cell), limits, :max_cell_bytes, "bytes per cell")
    end)

    row_bytes = json_size(cells)
    check_limit!(conn, row_bytes, limits, :max_row_bytes, "bytes per row")
    bytes = state.bytes + row_bytes + if(state.count == 0, do: 0, else: 1)
    check_limit!(conn, bytes, limits, :max_result_bytes, "bytes per result")

    %{state | rows: [row | state.rows], count: count, bytes: bytes}
  end

  defp json_size(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()

  defp check_deadline!(conn, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Postgrex.rollback(conn, :timeout)
    end
  end

  defp check_limit!(conn, value, limits, key, unit) do
    maximum = Keyword.fetch!(limits, key)

    if value > maximum do
      Postgrex.rollback(conn, {:result_limit_exceeded, "SQL result exceeds #{maximum} #{unit}."})
    end
  end

  defp query_error(%Postgrex.Error{postgres: %{code: :query_canceled}}),
    do: {:error, :timeout}

  defp query_error(%Postgrex.Error{postgres: %{message: msg}}),
    do: {:error, {:sql_error, msg}}

  defp query_error(error), do: {:error, {:system_error, error}}

  defp reseed(conn), do: Postgrex.query(conn, "SELECT setseed(#{@seed});", [])

  defp execute_setup(_conn, nil), do: :ok
  defp execute_setup(_conn, ""), do: :ok

  defp execute_setup(conn, setup_sql) do
    statements = parse_statements(setup_sql)

    Enum.reduce_while(statements, :ok, fn stmt, :ok ->
      # Setup may also contain SELECT or RETURNING. Bound its output without
      # reseeding between statements, which would change generated datasets.
      case bounded_query(conn, stmt, 15_000) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, {kind, msg}} when kind in [:sql_error, :result_limit_exceeded] ->
          {:halt, {:error, msg}}

        {:error, reason} ->
          {:halt, {:error, inspect(reason)}}
      end
    end)
  end

  defp connect_admin do
    runner_config() |> Postgrex.start_link()
  end

  defp connect_user(db_name, role_name, role_pass) do
    opts =
      runner_config()
      |> Keyword.put(:database, db_name)
      |> Keyword.put(:username, role_name)
      |> Keyword.put(:password, role_pass)

    Postgrex.start_link(opts)
  end

  defp create_role(conn, role_name, role_pass) do
    query = """
    CREATE ROLE "#{role_name}" WITH LOGIN PASSWORD '#{role_pass}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
    """

    case Postgrex.query(conn, query, []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_db(conn, db_name, role_name) do
    case Postgrex.query(conn, "CREATE DATABASE \"#{db_name}\" OWNER \"#{role_name}\";", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_db(conn, db_name) do
    Postgrex.query(conn, "DROP DATABASE IF EXISTS \"#{db_name}\" WITH (FORCE);", [])
  end

  defp drop_role(conn, role_name) do
    Postgrex.query(conn, "DROP ROLE IF EXISTS \"#{role_name}\";", [])
  end

  defp parse_statements(sql) when is_binary(sql) do
    sql
    |> String.to_charlist()
    |> do_parse(:default, [], [])
  end

  defp do_parse([], _state, current, acc) do
    stmt = current |> Enum.reverse() |> List.to_string() |> String.trim()
    if stmt == "", do: Enum.reverse(acc), else: Enum.reverse([stmt | acc])
  end

  defp do_parse([?; | rest], :default, current, acc) do
    stmt = current |> Enum.reverse() |> List.to_string() |> String.trim()

    if stmt == "" do
      do_parse(rest, :default, [], acc)
    else
      do_parse(rest, :default, [], [stmt | acc])
    end
  end

  defp do_parse([?-, ?- | rest], :default, current, acc),
    do: do_parse(rest, :line_comment, current, acc)

  defp do_parse([?\n | rest], :line_comment, current, acc),
    do: do_parse(rest, :default, [?\n | current], acc)

  defp do_parse([_ch | rest], :line_comment, current, acc),
    do: do_parse(rest, :line_comment, current, acc)

  defp do_parse([?/, ?* | rest], :default, current, acc),
    do: do_parse(rest, :block_comment, current, acc)

  defp do_parse([?*, ?/ | rest], :block_comment, current, acc),
    do: do_parse(rest, :default, current, acc)

  defp do_parse([_ch | rest], :block_comment, current, acc),
    do: do_parse(rest, :block_comment, current, acc)

  defp do_parse([?$, ?$ | rest], :default, current, acc),
    do: do_parse(rest, :dollar_quote, [?$, ?$ | current], acc)

  defp do_parse([?$, ?$ | rest], :dollar_quote, current, acc),
    do: do_parse(rest, :default, [?$, ?$ | current], acc)

  defp do_parse([?', ?' | rest], :single_quote, current, acc) do
    do_parse(rest, :single_quote, [?', ?' | current], acc)
  end

  defp do_parse([?' | rest], :default, current, acc),
    do: do_parse(rest, :single_quote, [?' | current], acc)

  defp do_parse([?' | rest], :single_quote, current, acc),
    do: do_parse(rest, :default, [?' | current], acc)

  defp do_parse([?" | rest], :default, current, acc),
    do: do_parse(rest, :double_quote, [?" | current], acc)

  defp do_parse([?" | rest], :double_quote, current, acc),
    do: do_parse(rest, :default, [?" | current], acc)

  defp do_parse([ch | rest], state, current, acc) do
    do_parse(rest, state, [ch | current], acc)
  end

  defp runner_config do
    config = Application.get_env(:athena, __MODULE__, [])
    url = Keyword.get(config, :url) || "ecto://postgres:postgres@127.0.0.1:5432/postgres"

    parse_db_url(url)
  end

  defp parse_db_url(url) do
    uri = URI.parse(url)
    {username, password} = parse_userinfo(uri.userinfo)

    [
      username: username,
      password: password,
      hostname: uri.host || "127.0.0.1",
      port: uri.port || 5432,
      database: clean_database_name(uri.path)
    ]
  end

  defp parse_userinfo(nil), do: {"postgres", "postgres"}

  defp parse_userinfo(userinfo) do
    case String.split(userinfo, ":") do
      [user, pass] -> {user, pass}
      [user] -> {user, "postgres"}
      _ -> {"postgres", "postgres"}
    end
  end

  defp clean_database_name(nil), do: "postgres"
  defp clean_database_name(""), do: "postgres"
  defp clean_database_name(path), do: String.trim_leading(path, "/")
end
