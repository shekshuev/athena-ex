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

  test "ClickHouse executes a SummingMergeTree setup and verifies its seeded data" do
    challenge = %CodeChallenge{
      language: "sql",
      database_engine: "clickhouse",
      time_limit: 2.0,
      setup_sql: """
      CREATE TABLE summing_mt (
        id UInt32,
        val UInt32,
        example UInt32, -- a non-key column; trailing commas are valid ClickHouse SQL
      ) ENGINE = SummingMergeTree(val) ORDER BY (id);
      INSERT INTO summing_mt SELECT 1, (number + 1) * 10, (number + 1) * 100 FROM numbers(3);
      INSERT INTO summing_mt SELECT 1, 10, 100;
      """,
      solution_code: "SELECT sum(val) AS total FROM summing_mt"
    }

    result = Verifier.verify(challenge.solution_code, challenge, 1)
    assert result.status == :accepted
    assert [test_result] = result.test_results
    assert Jason.decode!(test_result.stdout)["rows"] == [[70]]
  end

  test "ClickHouse permits local MergeTree variants under restricted credentials" do
    assert {:ok, :checked} =
             ClickHouse.execute_in_sandbox(1, nil, fn conn ->
               for {name, engine} <- [
                     {"replacing", "ReplacingMergeTree(version)"},
                     {"aggregating", "AggregatingMergeTree"},
                     {"coalescing", "CoalescingMergeTree"},
                     {"collapsing", "CollapsingMergeTree(sign)"},
                     {"versioned", "VersionedCollapsingMergeTree(sign, version)"}
                   ] do
                 assert {:ok, _} =
                          ClickHouse.query(
                            conn,
                            "CREATE TABLE #{name} (id UInt32, val UInt32, version UInt32, sign Int8) ENGINE=#{engine} ORDER BY id",
                            2
                          )

                 assert {:ok, _} =
                          ClickHouse.query(conn, "INSERT INTO #{name} VALUES (1, 10, 1, 1)", 2)

                 assert {:ok, %{rows: [[10]]}} =
                          ClickHouse.query(conn, "SELECT val FROM #{name}", 2)
               end

               :checked
             end)
  end

  test "ClickHouse supports Log engines and local Null, Set and Join tables" do
    assert {:ok, :checked} =
             ClickHouse.execute_in_sandbox(1, nil, fn conn ->
               for engine <- ["Log", "TinyLog", "StripeLog"] do
                 assert {:ok, _} =
                          ClickHouse.query(
                            conn,
                            "CREATE TABLE t_#{engine} (id UInt32) ENGINE=#{engine}",
                            2
                          )

                 assert {:ok, _} = ClickHouse.query(conn, "INSERT INTO t_#{engine} VALUES (7)", 2)

                 assert {:ok, %{rows: [[7]]}} =
                          ClickHouse.query(conn, "SELECT id FROM t_#{engine}", 2)
               end

               assert {:ok, _} =
                        ClickHouse.query(
                          conn,
                          "CREATE TABLE null_values (id UInt32) ENGINE=Null",
                          2
                        )

               assert {:ok, _} = ClickHouse.query(conn, "INSERT INTO null_values VALUES (7)", 2)

               assert {:ok, %{rows: [[0]]}} =
                        ClickHouse.query(conn, "SELECT count() FROM null_values", 2)

               assert {:ok, _} =
                        ClickHouse.query(
                          conn,
                          "CREATE TABLE set_values (id UInt32) ENGINE=Set",
                          2
                        )

               assert {:ok, _} = ClickHouse.query(conn, "INSERT INTO set_values VALUES (7)", 2)

               assert {:ok, %{rows: [[1]]}} =
                        ClickHouse.query(conn, "SELECT toUInt32(7) IN set_values AS found", 2)

               assert {:ok, _} =
                        ClickHouse.query(
                          conn,
                          "CREATE TABLE join_values (id UInt32, val String) ENGINE=Join(ANY, LEFT, id)",
                          2
                        )

               assert {:ok, _} =
                        ClickHouse.query(conn, "INSERT INTO join_values VALUES (7, 'seven')", 2)

               assert {:ok, %{rows: [["seven"]]}} =
                        ClickHouse.query(
                          conn,
                          "SELECT joinGet('join_values', 'val', toUInt32(7)) AS val",
                          2
                        )

               :checked
             end)
  end

  test "ClickHouse permits GraphiteMergeTree but still requires server rollup configuration" do
    assert {:ok, {:error, {:sql_error, message}}} =
             ClickHouse.execute_in_sandbox(1, nil, fn conn ->
               ClickHouse.query(
                 conn,
                 "CREATE TABLE graphite (Path String, Time DateTime, Value Float64, Version UInt64) ENGINE=GraphiteMergeTree('athena_missing_rollup') ORDER BY (Path, Time)",
                 2
               )
             end)

    assert message =~ "athena_missing_rollup"
    refute message =~ "ACCESS_DENIED"
  end

  test "ClickHouse reads engine grants from runtime configuration for each sandbox" do
    configure_engines(["Log"])

    assert {:ok, :restricted} =
             ClickHouse.execute_in_sandbox(1, nil, fn conn ->
               assert {:ok, _} =
                        ClickHouse.query(conn, "CREATE TABLE permitted (id UInt32) ENGINE=Log", 2)

               assert {:error, {:sql_error, message}} =
                        ClickHouse.query(
                          conn,
                          "CREATE TABLE forbidden (id UInt32) ENGINE=MergeTree ORDER BY id",
                          2
                        )

               assert message =~ "ACCESS_DENIED"
               :restricted
             end)
  end

  test "ClickHouse rejects malformed engine configuration instead of interpolating grants" do
    previous = Application.fetch_env!(:athena, ClickHouse)
    on_exit(fn -> Application.put_env(:athena, ClickHouse, previous) end)

    for invalid <- [["*"], ["Memory; SELECT 1"], [nil], "Log"] do
      Application.put_env(
        :athena,
        ClickHouse,
        Keyword.put(previous, :allowed_table_engines, invalid)
      )

      assert_raise ArgumentError, ~r/allowed_table_engines/, fn ->
        ClickHouse.execute_in_sandbox(1, nil, fn _ ->
          flunk("Invalid grants must not execute student code")
        end)
      end
    end
  end

  defp configure_engines(engines) do
    previous = Application.fetch_env!(:athena, ClickHouse)
    on_exit(fn -> Application.put_env(:athena, ClickHouse, previous) end)

    Application.put_env(
      :athena,
      ClickHouse,
      Keyword.put(previous, :allowed_table_engines, engines)
    )
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
                     "CREATE TABLE escape (x UInt32) ENGINE=Distributed('forbidden', 'db', 'table')",
                     "CREATE TABLE escape (x UInt32) ENGINE=ReplicatedMergeTree('/forbidden', 'replica') ORDER BY x",
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
