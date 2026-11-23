defmodule Athena.Execution.DatabaseRunner do
  @moduledoc "Dispatches SQL sandboxes without exposing driver-specific connections to verification."

  alias Athena.Execution.Database.{ClickHouse, MySQL}
  alias Athena.Execution.SqlRunner

  @engines [
    {"PostgreSQL", "postgresql"},
    {"MySQL / MariaDB", "mysql"},
    {"ClickHouse", "clickhouse"}
  ]

  def options, do: @engines
  def engines, do: Enum.map(@engines, &elem(&1, 1))

  def adapter("postgresql"), do: SqlRunner
  def adapter("mysql"), do: MySQL
  def adapter("clickhouse"), do: ClickHouse

  def execute_in_sandbox(engine, box_id, setup, callback) do
    adapter = adapter(engine)
    adapter.execute_in_sandbox(box_id, setup, &callback.({adapter, &1}))
  end

  def query({adapter, conn}, sql, timeout), do: adapter.query(conn, sql, timeout)
end
