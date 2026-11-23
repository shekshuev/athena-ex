defmodule Athena.Execution.Database.ClickHouse do
  @moduledoc "Ch-backed sandbox with database-scoped grants, engine allowlist and immutable resource settings."
  @behaviour Athena.Execution.Database.Adapter

  alias Athena.Execution.Database.{Collector, Deadline, Limits, Sandbox, Statements}

  @impl true
  def execute_in_sandbox(box_id, setup, callback),
    do: Sandbox.execute(__MODULE__, box_id, setup, callback)

  def dialect, do: "clickhouse"

  def connect_admin, do: Ch.start_link(options())

  def connect_user(credentials) do
    options()
    |> Keyword.merge(
      database: credentials.database,
      username: credentials.username,
      password: credentials.password
    )
    |> Ch.start_link()
  end

  def provision(admin, %{database: database, username: user, password: password}) do
    limits = Limits.config()

    settings = [
      "max_execution_time = 15 MIN 0.001 MAX 15",
      "max_memory_usage = 134217728 CONST",
      "max_result_rows = #{limits[:max_result_rows]} CONST",
      "max_result_bytes = #{limits[:max_result_bytes]} CONST",
      "result_overflow_mode = 'throw' CONST",
      "timeout_overflow_mode = 'throw' CONST",
      "max_rows_to_read = 10000000 CONST",
      "max_bytes_to_read = 134217728 CONST",
      "read_overflow_mode = 'throw' CONST",
      "max_threads = 2 CONST",
      "max_block_size = 100 CONST",
      "max_insert_block_size = 100 CONST",
      "mutations_sync = 2 CONST",
      "async_insert = 0 CONST"
    ]

    commands = [
      "CREATE DATABASE `#{database}`",
      "CREATE USER `#{user}` IDENTIFIED WITH sha256_password BY '#{password}' SETTINGS #{Enum.join(settings, ", ")}",
      "GRANT SELECT, INSERT, CREATE TABLE, DROP TABLE, ALTER TABLE, TRUNCATE ON `#{database}`.* TO `#{user}`",
      "GRANT TABLE ENGINE ON Memory TO `#{user}`",
      "GRANT TABLE ENGINE ON MergeTree TO `#{user}`"
    ]

    Enum.reduce_while(commands, :ok, fn sql, :ok ->
      case Ch.query(admin, sql) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def cleanup(admin, %{database: database, username: user}) do
    Ch.query(admin, "KILL QUERY WHERE user = '#{user}' SYNC")
    Ch.query(admin, "DROP DATABASE IF EXISTS `#{database}` SYNC")
    Ch.query(admin, "DROP USER IF EXISTS `#{user}`")
    :ok
  end

  @impl true
  def query(conn, sql, seconds) do
    with {:ok, statement} <- Statements.single(sql, dialect()) do
      query_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      Deadline.run(__MODULE__, query_id, trunc(seconds * 1_000), fn ->
        DBConnection.run(conn, &collect_query(&1, statement, query_id, seconds),
          timeout: trunc(seconds * 1_000) + 2_000
        )
      end)
    end
  rescue
    error in [Ch.Error, DBConnection.ConnectionError] -> query_error(error)
  end

  defp collect_query(conn, statement, query_id, seconds) do
    conn
    |> Ch.stream(statement, [],
      settings: [max_execution_time: seconds],
      headers: [{"x-clickhouse-query-id", query_id}],
      timeout: trunc(seconds * 1_000) + 1_000
    )
    |> Collector.collect(seconds)
  end

  def cancel(query_id) do
    case connect_admin() do
      {:ok, admin} ->
        try do
          Ch.query(admin, "KILL QUERY WHERE query_id = '#{query_id}' SYNC")
        after
          GenServer.stop(admin)
        end

      _ ->
        :ok
    end
  end

  defp query_error(%Ch.Error{code: code}) when code in [159, 160, 394], do: {:error, :timeout}

  defp query_error(%Ch.Error{code: code}) when code in [241, 396, 158, 307],
    do: {:error, {:result_limit_exceeded, "SQL result or query resource limit exceeded."}}

  defp query_error(%Ch.Error{message: message}), do: {:error, {:sql_error, message}}
  defp query_error(%DBConnection.ConnectionError{}), do: {:error, :timeout}
  defp query_error(error), do: {:error, {:system_error, error}}

  defp options do
    config = Application.fetch_env!(:athena, __MODULE__)
    uri = URI.parse(Keyword.fetch!(config, :url))
    Sandbox.connection_options(__MODULE__, 8123) |> Keyword.put(:scheme, uri.scheme)
  end
end
