defmodule Athena.Execution.Database.MySQL do
  @moduledoc "MyXQL sandbox for MariaDB: per-attempt database and explicit database-scoped grants."
  @behaviour Athena.Execution.Database.Adapter

  @commands_without_rows ~w(CREATE ALTER DROP INSERT UPDATE DELETE TRUNCATE RENAME SET USE
    BEGIN START COMMIT ROLLBACK SAVEPOINT RELEASE LOCK UNLOCK GRANT REVOKE KILL FLUSH LOAD DO PREPARE DEALLOCATE)

  alias Athena.Execution.Database.{Collector, Deadline, Limits, Result, Sandbox, Statements}

  @impl true
  def execute_in_sandbox(box_id, setup, callback),
    do: Sandbox.execute(__MODULE__, box_id, setup, callback)

  def dialect, do: "mysql"

  def connect_admin, do: MyXQL.start_link(options())

  def connect_user(credentials) do
    options()
    |> Keyword.merge(
      database: credentials.database,
      username: credentials.username,
      password: credentials.password
    )
    |> MyXQL.start_link()
  end

  def provision(admin, %{database: database, username: user, password: password}) do
    grant_database = String.replace(database, "_", "\\_")

    commands = [
      "CREATE DATABASE `#{database}`",
      "CREATE USER '#{user}'@'%' IDENTIFIED BY '#{password}' WITH MAX_USER_CONNECTIONS 2",
      "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX ON `#{grant_database}`.* TO '#{user}'@'%'"
    ]

    Enum.reduce_while(commands, :ok, fn sql, :ok ->
      case MyXQL.query(admin, sql, [], query_type: :text) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def cleanup(admin, %{database: database, username: user}) do
    # Kill all connections for this unique account before dropping its objects.
    case MyXQL.query(admin, "SELECT ID FROM information_schema.PROCESSLIST WHERE USER = ?", [user]) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn [id] ->
          MyXQL.query(admin, "KILL CONNECTION #{id}", [], query_type: :text)
        end)

      _ ->
        :ok
    end

    MyXQL.query(admin, "DROP DATABASE IF EXISTS `#{database}`", [], query_type: :text)
    MyXQL.query(admin, "DROP USER IF EXISTS '#{user}'@'%'", [], query_type: :text)
    :ok
  end

  @impl true
  def query(conn, sql, seconds) do
    with {:ok, statement} <- Statements.single(sql, dialect()),
         {:ok, %{rows: [[connection_id]]}} <- MyXQL.query(conn, "SELECT CONNECTION_ID()", []) do
      Deadline.run(__MODULE__, connection_id, trunc(seconds * 1_000), fn ->
        DBConnection.run(conn, &execute_statement(&1, statement, seconds),
          timeout: trunc(seconds * 1_000) + 2_000
        )
      end)
    end
  rescue
    error in [MyXQL.Error, DBConnection.ConnectionError] -> query_error(error)
  end

  defp execute_statement(conn, statement, seconds) do
    opts = [timeout: trunc(seconds * 1_000) + 1_000]
    words = Statements.words(statement)
    # Cursors bound client allocations per fetch. DDL/DML with no result set
    # uses query/4 because MyXQL cursors require a result set.
    if List.first(words) not in @commands_without_rows or "RETURNING" in words do
      conn
      |> MyXQL.stream(statement, [], Keyword.put(opts, :max_rows, Sandbox.stream_rows()))
      |> Collector.collect(seconds)
    else
      execute_command(conn, statement, opts)
    end
  end

  defp execute_command(conn, statement, opts) do
    case MyXQL.query(conn, statement, [], Keyword.put(opts, :query_type, :binary)) do
      {:ok, result} ->
        Limits.validate(%Result{
          columns: result.columns,
          rows: result.rows,
          num_rows: result.num_rows
        })

      {:error, error} ->
        query_error(error)
    end
  end

  def cancel(connection_id) do
    case connect_admin() do
      {:ok, admin} ->
        try do
          MyXQL.query(admin, "KILL CONNECTION #{connection_id}", [], query_type: :text)
        after
          GenServer.stop(admin)
        end

      _ ->
        :ok
    end
  end

  defp query_error(%MyXQL.Error{mysql: %{code: code}}) when code in [1969, 1317, 3024],
    do: {:error, :timeout}

  defp query_error(%MyXQL.Error{message: message}), do: {:error, {:sql_error, message}}
  defp query_error(%DBConnection.ConnectionError{}), do: {:error, :timeout}
  defp query_error(error), do: {:error, {:system_error, error}}

  defp options, do: Sandbox.connection_options(__MODULE__, 3306)
end
