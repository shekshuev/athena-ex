defmodule Athena.Execution.DatabaseRunnerTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Athena.Content.CodeChallenge
  alias Athena.Execution.{SqlRunner, Verifier}
  alias Athena.Execution.Database.{ClickHouse, MySQL}

  for {engine, adapter} <- [{"mysql", MySQL}, {"clickhouse", ClickHouse}] do
    describe engine do
      setup do
        %{
          engine: unquote(engine),
          adapter: unquote(adapter),
          box_id: System.unique_integer([:positive])
        }
      end

      test "restricted setup, query results, row ordering and wrong answers", ctx do
        challenge =
          challenge(ctx,
            setup_sql: setup_sql(ctx.engine),
            solution_code: "SELECT id FROM items ORDER BY id"
          )

        assert Verifier.verify("SELECT id FROM items ORDER BY id", challenge, ctx.box_id).status ==
                 :accepted

        assert Verifier.verify("SELECT id FROM items ORDER BY id DESC", challenge, ctx.box_id).status ==
                 :wrong_answer

        assert Verifier.verify(
                 "SELECT id FROM items ORDER BY id DESC",
                 %{challenge | result_order: "ignore"},
                 ctx.box_id
               ).status == :accepted

        assert Verifier.verify("SELECT id FROM items WHERE id=1", challenge, ctx.box_id).status ==
                 :wrong_answer
      end

      test "state verification observes writes and checks under restricted credentials", ctx do
        challenge =
          challenge(ctx,
            setup_sql: setup_sql(ctx.engine),
            evaluation_mode: "state_verification",
            check_sql:
              "SELECT CASE WHEN count(*)=3 THEN 'OK' ELSE 'Missing row' END AS verdict FROM items"
          )

        assert Verifier.verify("INSERT INTO items VALUES (3, 'three')", challenge, ctx.box_id).status ==
                 :accepted

        assert Verifier.verify("SELECT 1", challenge, ctx.box_id).status == :wrong_answer
      end

      test "reference and student see identical generated seed values", ctx do
        setup =
          if ctx.engine == "mysql",
            do: "CREATE TABLE seeded_values AS SELECT UUID() AS value",
            else: "CREATE TABLE seeded_values ENGINE=Memory AS SELECT generateUUIDv4() AS value"

        challenge =
          challenge(ctx, setup_sql: setup, solution_code: "SELECT value FROM seeded_values")

        result = Verifier.verify("SELECT value FROM seeded_values", challenge, ctx.box_id)
        assert result.status == :accepted, inspect(result)
      end

      test "syntax and setup failures are classified and cleaned up", ctx do
        assert {:error, {:setup_error, _}} =
                 sandbox(ctx, "CREAT TABLE broken (id INT)", fn _ -> flunk("invalid setup") end)

        assert {:ok, {:error, {:sql_error, _}}} =
                 sandbox(ctx, nil, &ctx.adapter.query(&1, "SELEC 1", 2))

        challenge = challenge(ctx, solution_code: "SELECT 1 AS n")
        assert Verifier.verify("SELEC 1", challenge, ctx.box_id).status == :runtime_error

        assert Verifier.verify("SELECT 1", %{challenge | solution_code: "SELEC 1"}, ctx.box_id).status ==
                 :compilation_error
      end

      test "databases and users disappear after success, setup error and callback crash", ctx do
        before = inventory(ctx.adapter)
        assert {:ok, :done} = sandbox(ctx, setup_sql(ctx.engine), fn _ -> :done end)
        assert inventory(ctx.adapter) == before

        assert {:error, {:setup_error, _}} =
                 sandbox(ctx, "SELEC 1", fn _ -> flunk("setup failed") end)

        assert inventory(ctx.adapter) == before
        assert_raise RuntimeError, "crash", fn -> sandbox(ctx, nil, fn _ -> raise "crash" end) end
        assert inventory(ctx.adapter) == before
      end

      test "attempts with identical box IDs cannot read or change each other's data", ctx do
        assert {:ok, :isolated} =
                 sandbox(ctx, setup_sql(ctx.engine), fn first ->
                   {:ok, %{rows: [[database]]}} =
                     ctx.adapter.query(first, "SELECT database() AS name", 2)

                   assert {:ok, :denied} =
                            sandbox(ctx, nil, fn second ->
                              assert {:error, {:sql_error, _}} =
                                       ctx.adapter.query(
                                         second,
                                         "SELECT * FROM `#{database}`.items",
                                         2
                                       )

                              assert {:error, {:sql_error, _}} =
                                       ctx.adapter.query(
                                         second,
                                         "DROP TABLE `#{database}`.items",
                                         2
                                       )

                              :denied
                            end)

                   assert {:ok, %{rows: [[2]]}} =
                            ctx.adapter.query(first, "SELECT count(*) AS n FROM items", 2)

                   :isolated
                 end)
      end

      test "cannot create users, grant privileges or create unrelated databases even in setup",
           ctx do
        for sql <- [
              "CREATE USER intruder IDENTIFIED BY 'bad'",
              "CREATE DATABASE intruder",
              "GRANT ALL ON *.* TO intruder"
            ] do
          assert {:ok, {:error, {:sql_error, _}}} =
                   sandbox(ctx, nil, &ctx.adapter.query(&1, sql, 2))

          assert {:error, {:setup_error, _}} =
                   sandbox(ctx, sql, fn _ -> flunk("privileged setup") end)
        end
      end

      test "output budgets reject partial results in setup, reference, student and check", ctx do
        previous = Application.fetch_env!(:athena, SqlRunner)

        Application.put_env(
          :athena,
          SqlRunner,
          Keyword.merge(previous, max_result_rows: 1, max_cell_bytes: 16)
        )

        on_exit(fn -> Application.put_env(:athena, SqlRunner, previous) end)
        sql = "SELECT id FROM items ORDER BY id"

        assert {:ok, {:error, {:result_limit_exceeded, _}}} =
                 sandbox(ctx, setup_sql(ctx.engine), &ctx.adapter.query(&1, sql, 2))

        assert {:error, {:setup_error, _}} =
                 sandbox(ctx, setup_sql(ctx.engine) <> "; " <> sql, fn _ ->
                   flunk("oversized setup")
                 end)

        challenge =
          challenge(ctx,
            setup_sql: setup_sql(ctx.engine),
            solution_code: "SELECT id FROM items WHERE id=1"
          )

        assert Verifier.verify(sql, challenge, ctx.box_id).status == :memory_limit_exceeded

        assert Verifier.verify("SELECT 1", %{challenge | solution_code: sql}, ctx.box_id).status ==
                 :compilation_error

        challenge = %{challenge | evaluation_mode: "state_verification", check_sql: sql}
        assert Verifier.verify("SELECT 1", challenge, ctx.box_id).status == :memory_limit_exceeded

        assert {:ok, {:error, {:result_limit_exceeded, _}}} =
                 sandbox(ctx, nil, &ctx.adapter.query(&1, "SELECT repeat('x', 100) AS n", 2))
      end

      test "JSON byte budgets include rows, cells and separators across fetches", ctx do
        previous = Application.fetch_env!(:athena, SqlRunner)
        on_exit(fn -> Application.put_env(:athena, SqlRunner, previous) end)

        Application.put_env(
          :athena,
          SqlRunner,
          Keyword.merge(previous,
            max_result_rows: 100,
            max_result_bytes: 12,
            max_row_bytes: 100,
            max_cell_bytes: 50,
            stream_max_rows: 1
          )
        )

        assert {:ok, {:error, {:result_limit_exceeded, _}}} =
                 sandbox(
                   ctx,
                   nil,
                   &ctx.adapter.query(
                     &1,
                     "SELECT 1 AS n UNION ALL SELECT 2 AS n UNION ALL SELECT 3 AS n",
                     2
                   )
                 )

        Application.put_env(
          :athena,
          SqlRunner,
          Keyword.merge(previous, max_row_bytes: 20, max_cell_bytes: 16)
        )

        assert {:ok, {:error, {:result_limit_exceeded, _}}} =
                 sandbox(
                   ctx,
                   nil,
                   &ctx.adapter.query(&1, "SELECT repeat('x', 12) AS a, repeat('y', 12) AS b", 2)
                 )
      end

      test "multiple statements cannot disable limits or smuggle privileged commands", ctx do
        assert {:ok, {:error, {:sql_error, _}}} =
                 sandbox(ctx, nil, &ctx.adapter.query(&1, "SELECT 1; SELECT 2", 2))
      end
    end
  end

  test "MySQL denies host files, local infile and server account tables" do
    ctx = %{engine: "mysql", adapter: MySQL, box_id: 1}

    assert {:ok, :denied} =
             sandbox(ctx, "CREATE TABLE files (content TEXT)", fn conn ->
               assert {:ok, %{rows: [[nil]]}} =
                        MySQL.query(conn, "SELECT LOAD_FILE('/etc/passwd') AS content", 2)

               for sql <- [
                     "SELECT * FROM mysql.user",
                     "SELECT 'bad' INTO OUTFILE '/tmp/athena-escape'",
                     "LOAD DATA INFILE '/etc/passwd' INTO TABLE files",
                     "LOAD DATA LOCAL INFILE '/etc/passwd' INTO TABLE files"
                   ] do
                 assert {:error, {:sql_error, _}} = MySQL.query(conn, sql, 2)
               end

               :denied
             end)
  end

  test "MySQL cancels server work and cleans up on timeout" do
    before = inventory(MySQL)

    assert {:ok, {:error, :timeout}} =
             MySQL.execute_in_sandbox(1, nil, &MySQL.query(&1, "SELECT SLEEP(5)", 0.1))

    assert inventory(MySQL) == before
  end

  test "ClickHouse denies files, external sources, dangerous engines and weakened limits" do
    assert {:ok, :denied} =
             ClickHouse.execute_in_sandbox(1, nil, fn conn ->
               for sql <- [
                     "SELECT * FROM file('/etc/passwd', 'LineAsString')",
                     "SELECT * FROM url('http://127.0.0.1:9000', 'LineAsString')",
                     "SELECT * FROM remote('127.0.0.1', 'system', 'one')",
                     "CREATE TABLE escape (x String) ENGINE=File(LineAsString)",
                     "CREATE TABLE escape (x String) ENGINE=URL('http://127.0.0.1:9000', 'LineAsString')",
                     "SELECT 1 SETTINGS max_memory_usage=0",
                     "SELECT 1 SETTINGS max_result_rows=0",
                     "SELECT 1 SETTINGS max_execution_time=0"
                   ] do
                 assert {:error, {:sql_error, message}} = ClickHouse.query(conn, sql, 2)
                 message = String.downcase(message)

                 assert message =~ "privilege" or message =~ "constraint" or message =~ "readonly",
                        "#{sql}: #{message}"
               end

               :denied
             end)
  end

  test "ClickHouse rejects custom text formats instead of comparing empty results" do
    assert {:ok, {:error, {:sql_error, _}}} =
             ClickHouse.execute_in_sandbox(
               1,
               nil,
               &ClickHouse.query(&1, "SELECT 1 FORMAT TabSeparated", 2)
             )
  end

  test "ClickHouse cancels server work and cleans up on timeout" do
    before = inventory(ClickHouse)

    assert {:ok, {:error, :timeout}} =
             ClickHouse.execute_in_sandbox(1, nil, &ClickHouse.query(&1, "SELECT sleep(2)", 0.1))

    assert inventory(ClickHouse) == before
  end

  defp challenge(ctx, attrs) do
    struct!(
      CodeChallenge,
      Keyword.merge([language: "sql", database_engine: ctx.engine, time_limit: 2.0], attrs)
    )
  end

  defp sandbox(ctx, setup, callback),
    do: ctx.adapter.execute_in_sandbox(ctx.box_id, setup, callback)

  defp setup_sql("mysql"),
    do:
      "CREATE TABLE items (id INT PRIMARY KEY, name TEXT); INSERT INTO items VALUES (1, 'one'), (2, 'two')"

  defp setup_sql("clickhouse"),
    do:
      "CREATE TABLE items (id Int32, name String) ENGINE=MergeTree ORDER BY id; INSERT INTO items VALUES (1, 'one'), (2, 'two')"

  defp inventory(adapter) do
    # Connections are supervised by the test, including assertion failures.
    options =
      Athena.Execution.Database.Sandbox.connection_options(
        adapter,
        if(adapter == MySQL, do: 3307, else: 8124)
      )

    driver = if adapter == MySQL, do: MyXQL, else: Ch
    options = if adapter == ClickHouse, do: Keyword.put(options, :scheme, "http"), else: options
    conn = start_supervised!({driver, options}, id: make_ref())

    queries =
      if adapter == MySQL do
        [
          "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE 'athena_%' ORDER BY SCHEMA_NAME",
          "SELECT User FROM mysql.user WHERE User LIKE 'u_%' ORDER BY User"
        ]
      else
        [
          "SELECT name FROM system.databases WHERE startsWith(name, 'athena_') ORDER BY name",
          "SELECT name FROM system.users WHERE startsWith(name, 'u_') ORDER BY name"
        ]
      end

    Enum.map(queries, fn sql ->
      {:ok, result} = driver.query(conn, sql)
      result.rows
    end)
  end
end
