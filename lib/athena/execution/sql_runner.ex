defmodule Athena.Execution.SqlRunner do
  @moduledoc """
  Low-level runner for executing SQL in an isolated, ephemeral PostgreSQL database.
  Handles database & role lifecycle:
    create restricted role -> create db owned by role -> run setup & student code as restricted user -> cleanup.
  """
  require Logger

  @doc """
  Runs a callback function within an ephemeral sandbox database under an unprivileged user role.
  Creates the database directly owned by the restricted role, then executes both setup_sql
  and the student callback under that restricted connection.
  Always drops the sandbox database and temporary role upon completion.
  """
  @spec execute_in_sandbox(integer(), String.t() | nil, (pid() -> result)) ::
          {:ok, result} | {:error, {:setup_error, String.t()} | {:system_error, any()}}
        when result: any()
  def execute_in_sandbox(box_id, setup_sql, callback) do
    db_name = "athena_sandbox_#{box_id}"
    role_name = "athena_user_#{box_id}"
    role_pass = "pass_#{box_id}"

    case connect_admin() do
      {:ok, admin_conn} ->
        try do
          with :ok <- create_role(admin_conn, role_name, role_pass),
               :ok <- create_db(admin_conn, db_name, role_name),
               {:ok, user_conn} <- connect_user(db_name, role_name, role_pass) do
            try do
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
  """
  @spec query(pid(), String.t(), float()) ::
          {:ok, Postgrex.Result.t()}
          | {:error, :timeout | {:sql_error, String.t()} | {:system_error, any()}}
  def query(conn, sql, time_limit_sec) do
    statement_timeout_ms = trunc((time_limit_sec || 2.0) * 1000)
    client_timeout_ms = statement_timeout_ms + 2_000

    Postgrex.query(conn, "SET statement_timeout = #{statement_timeout_ms};", [])

    case Postgrex.query(conn, sql, [], timeout: client_timeout_ms) do
      {:ok, result} ->
        {:ok, result}

      {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} ->
        {:error, :timeout}

      {:error, %Postgrex.Error{postgres: %{message: msg}}} ->
        {:error, {:sql_error, msg}}

      {:error, reason} ->
        {:error, {:system_error, reason}}
    end
  end

  defp execute_setup(_conn, nil), do: :ok
  defp execute_setup(_conn, ""), do: :ok

  defp execute_setup(conn, setup_sql) do
    statements = parse_statements(setup_sql)

    Enum.reduce_while(statements, :ok, fn stmt, :ok ->
      case Postgrex.query(conn, stmt, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, %Postgrex.Error{postgres: %{message: msg}}} -> {:halt, {:error, msg}}
        {:error, reason} -> {:halt, {:error, inspect(reason)}}
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
    userinfo = uri.userinfo && String.split(uri.userinfo, ":")

    [
      username: (userinfo && Enum.at(userinfo, 0)) || "postgres",
      password: (userinfo && Enum.at(userinfo, 1)) || "postgres",
      hostname: uri.host || "127.0.0.1",
      port: uri.port || 5432,
      database: (uri.path && String.trim_leading(uri.path, "/")) || "postgres"
    ]
  end
end
