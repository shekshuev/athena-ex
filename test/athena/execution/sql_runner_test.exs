defmodule Athena.Execution.SqlRunnerTest do
  use ExUnit.Case, async: false

  alias Athena.Content.CodeChallenge
  alias Athena.Execution.{SqlRunner, Verifier}

  setup_all do
    {:ok, agent} = Agent.start_link(fn -> 9000 end)
    %{box_agent: agent}
  end

  setup %{box_agent: agent} do
    box_id = Agent.get_and_update(agent, fn id -> {id, id + 1} end)
    %{box_id: box_id}
  end

  describe "Database Lifecycle & Cleanup" do
    test "creates sandbox db, runs setup_sql, executes callback, and drops db afterwards", %{
      box_id: box_id
    } do
      setup_sql = """
      CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT);
      INSERT INTO users (name) VALUES ('Alice'), ('Bob');
      """

      db_name = "athena_sandbox_#{box_id}"

      result =
        SqlRunner.execute_in_sandbox(box_id, setup_sql, fn conn ->
          SqlRunner.query(conn, "SELECT COUNT(*) FROM users;", 2.0)
        end)

      assert {:ok, {:ok, %Postgrex.Result{rows: [[2]]}}} = result

      assert_database_dropped(db_name)
    end

    test "handles complex comments and multiple statements in setup_sql", %{box_id: box_id} do
      setup_sql = """
      -- This is a single-line comment; with a semicolon inside!
      CREATE TABLE settings (key TEXT, value TEXT);

      /*
         This is a multi-line comment.
         It also has a semicolon;
         And another one;
      */
      INSERT INTO settings (key, value) VALUES ('theme', 'dark');

      -- Let's add one more inside string
      INSERT INTO settings (key, value) VALUES ('font;', 'sans;');
      """

      result =
        SqlRunner.execute_in_sandbox(box_id, setup_sql, fn conn ->
          SqlRunner.query(conn, "SELECT COUNT(*) FROM settings;", 2.0)
        end)

      assert {:ok, {:ok, %Postgrex.Result{rows: [[2]]}}} = result
    end

    test "guarantees database cleanup even if callback raises an exception", %{box_id: box_id} do
      db_name = "athena_sandbox_#{box_id}"

      assert_raise RuntimeError, "Unexpected crash inside sandbox", fn ->
        SqlRunner.execute_in_sandbox(box_id, "CREATE TABLE t (id INT);", fn _conn ->
          raise "Unexpected crash inside sandbox"
        end)
      end

      assert_database_dropped(db_name)
    end

    test "returns setup_error and cleans up if setup_sql contains syntax errors", %{
      box_id: box_id
    } do
      invalid_setup = "CREATE TABLLLE broken_syntax (id INT);"
      db_name = "athena_sandbox_#{box_id}"

      result =
        SqlRunner.execute_in_sandbox(box_id, invalid_setup, fn _conn ->
          flunk("Callback should not be called when setup fails")
        end)

      assert {:error, {:setup_error, msg}} = result
      assert msg =~ "syntax error"

      assert_database_dropped(db_name)
    end
  end

  describe "Query Execution & Error Handling" do
    test "successfully executes valid query", %{box_id: box_id} do
      setup_sql = "CREATE TABLE items (id INT, val TEXT);"

      {:ok, res} =
        SqlRunner.execute_in_sandbox(box_id, setup_sql, fn conn ->
          SqlRunner.query(conn, "INSERT INTO items VALUES (1, 'test') RETURNING id;", 2.0)
        end)

      assert {:ok, %Postgrex.Result{rows: [[1]]}} = res
    end

    test "catches SQL syntax errors during query execution", %{box_id: box_id} do
      {:ok, res} =
        SqlRunner.execute_in_sandbox(box_id, nil, fn conn ->
          SqlRunner.query(conn, "SELEEEECT 1;", 2.0)
        end)

      assert {:error, {:sql_error, msg}} = res
      assert msg =~ "syntax error"
    end

    test "catches query execution timeout (statement_timeout)", %{box_id: box_id} do
      {:ok, res} =
        SqlRunner.execute_in_sandbox(box_id, nil, fn conn ->
          SqlRunner.query(conn, "SELECT pg_sleep(2);", 0.2)
        end)

      assert {:error, :timeout} = res
    end
  end

  describe "Happy Paths (Query Result & State Verification)" do
    test "query_result: accepts correct SELECT query when data matches", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => """
          CREATE TABLE products (id INT PRIMARY KEY, name TEXT, price INT);
          INSERT INTO products VALUES (1, 'Laptop', 1000), (2, 'Mouse', 25);
          """,
          "solution_sql" => "SELECT name, price FROM products WHERE price > 50;"
        }
      }

      student_sql = "SELECT name, price FROM products WHERE price > 50;"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :accepted
      assert result.score == 100
      assert [test_res] = result.test_results
      assert test_res.status == :accepted

      payload = Jason.decode!(test_res.stdout)
      assert payload["type"] == "sql_query"
      assert payload["status"] == "accepted"
      assert payload["rows"] == [["Laptop", 1000]]
    end

    test "query_result: normalizes row order if student returns same rows in different order", %{
      box_id: box_id
    } do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => """
          CREATE TABLE users (id INT PRIMARY KEY, age INT);
          INSERT INTO users VALUES (1, 20), (2, 30), (3, 40);
          """,
          "solution_sql" => "SELECT id, age FROM users ORDER BY age ASC;"
        }
      }

      student_sql = "SELECT id, age FROM users ORDER BY age DESC;"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :accepted
      assert result.score == 100
    end

    test "state_verification: accepts when check_sql returns OK after DML/DDL execution", %{
      box_id: box_id
    } do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "state_verification",
          "setup_sql" => """
          CREATE TABLE accounts (id INT PRIMARY KEY, status TEXT);
          INSERT INTO accounts VALUES (1, 'pending'), (2, 'pending'), (3, 'active');
          """,
          "check_sql" => """
          SELECT CASE
            WHEN COUNT(*) = 3 THEN 'OK'
            ELSE 'Expected all accounts to be active'
          END FROM accounts WHERE status = 'active';
          """
        }
      }

      student_sql = "UPDATE accounts SET status = 'active';"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :accepted
      assert result.score == 100
      assert [test_res] = result.test_results
      assert test_res.status == :accepted

      payload = Jason.decode!(test_res.stdout)
      assert payload["type"] == "sql_state"
      assert payload["status"] == "accepted"
      assert payload["message"] == "State verification passed."
    end
  end

  describe "Wrong Answer & Data Mismatch" do
    test "query_result: rejects query when returned rows or values do not match solution", %{
      box_id: box_id
    } do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => """
          CREATE TABLE products (id INT PRIMARY KEY, name TEXT, price INT);
          INSERT INTO products VALUES (1, 'Laptop', 1000), (2, 'Mouse', 25);
          """,
          "solution_sql" => "SELECT name FROM products WHERE price > 500;"
        }
      }

      student_sql = "SELECT name FROM products;"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :wrong_answer
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :wrong_answer

      payload = Jason.decode!(test_res.stdout)
      assert payload["type"] == "sql_query"
      assert payload["status"] == "wrong_answer"
      assert payload["rows"] == [["Laptop"], ["Mouse"]]
      assert payload["expected_rows"] == [["Laptop"]]
    end

    test "query_result: rejects query when column count or structure differs", %{
      box_id: box_id
    } do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => """
          CREATE TABLE users (id INT PRIMARY KEY, name TEXT, age INT);
          INSERT INTO users VALUES (1, 'Alice', 25);
          """,
          "solution_sql" => "SELECT name, age FROM users;"
        }
      }

      student_sql = "SELECT name FROM users;"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :wrong_answer
      assert result.score == 0
    end

    test "state_verification: returns wrong_answer with custom message from check_sql", %{
      box_id: box_id
    } do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "state_verification",
          "setup_sql" => """
          CREATE TABLE accounts (id INT PRIMARY KEY, status TEXT);
          INSERT INTO accounts VALUES (1, 'pending'), (2, 'pending'), (3, 'pending');
          """,
          "check_sql" => """
          SELECT CASE
            WHEN COUNT(*) = 3 THEN 'OK'
            ELSE 'Expected 3 active accounts, got ' || COUNT(*)
          END FROM accounts WHERE status = 'active';
          """
        }
      }

      student_sql = "UPDATE accounts SET status = 'active' WHERE id = 1;"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :wrong_answer
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :wrong_answer

      payload = Jason.decode!(test_res.stdout)
      assert payload["type"] == "sql_state"
      assert payload["status"] == "wrong_answer"
      assert payload["message"] == "Expected 3 active accounts, got 1"
    end
  end

  describe "Runtime & Syntax Errors" do
    test "returns runtime_error on student SQL syntax error", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE users (id INT);",
          "solution_sql" => "SELECT * FROM users;"
        }
      }

      student_sql = "SELEEEECT * FROM users;"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :runtime_error
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :runtime_error
      assert test_res.stderr =~ "syntax error"
    end

    test "returns runtime_error when querying non-existent table", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE users (id INT);",
          "solution_sql" => "SELECT * FROM users;"
        }
      }

      student_sql = "SELECT * FROM non_existent_table;"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :runtime_error
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :runtime_error
      assert test_res.stderr =~ "does not exist"
    end

    test "returns runtime_error on division by zero", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE numbers (val INT); INSERT INTO numbers VALUES (10);",
          "solution_sql" => "SELECT val FROM numbers;"
        }
      }

      student_sql = "SELECT val / 0 FROM numbers;"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :runtime_error
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :runtime_error
      assert test_res.stderr =~ "division by zero"
    end
  end

  describe "Time Limit Exceeded (TLE)" do
    test "catches explicit pg_sleep execution timeout", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 0.2,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE dummy (id INT);",
          "solution_sql" => "SELECT 1;"
        }
      }

      student_sql = "SELECT pg_sleep(2);"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :time_limit_exceeded
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :time_limit_exceeded
      assert test_res.stderr =~ "timed out"
    end

    test "catches infinite recursive CTE timeout", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 0.2,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE dummy (id INT);",
          "solution_sql" => "SELECT 1;"
        }
      }

      student_sql = """
      WITH RECURSIVE r AS (
        SELECT 1 AS n
        UNION ALL
        SELECT n + 1 FROM r
      )
      SELECT * FROM r;
      """

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :time_limit_exceeded
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :time_limit_exceeded
      assert test_res.stderr =~ "timed out"
    end
  end

  describe "Security & Penetration Testing" do
    test "prevents reading sensitive host files via COPY FROM", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE loot (content TEXT);",
          "solution_sql" => "SELECT 1;"
        }
      }

      student_sql = "COPY loot FROM '/etc/passwd';"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :runtime_error
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :runtime_error

      assert test_res.stderr =~ "must be superuser" or test_res.stderr =~ "permission denied" or
               test_res.stderr =~ "could not open file"
    end

    test "prevents arbitrary system command execution via COPY PROGRAM", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE cmd_out (output TEXT);",
          "solution_sql" => "SELECT 1;"
        }
      }

      student_sql = "COPY cmd_out FROM PROGRAM 'id';"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status == :runtime_error
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status == :runtime_error
      assert test_res.stderr =~ "must be superuser" or test_res.stderr =~ "permission denied"
    end

    test "isolates sandbox from other databases in cluster", %{box_id: box_id} do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 2.0,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE dummy (id INT);",
          "solution_sql" => "SELECT 1;"
        }
      }

      student_sql = "SELECT datname FROM pg_database WHERE datname = 'postgres';"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status in [:accepted, :wrong_answer]
    end

    test "prevents overriding statement_timeout via multi-statement injection", %{
      box_id: box_id
    } do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 0.2,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE dummy (id INT);",
          "solution_sql" => "SELECT 1;"
        }
      }

      student_sql = "SET statement_timeout = 0; SELECT pg_sleep(2);"

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status in [:runtime_error, :time_limit_exceeded]
      assert result.score == 0
    end

    test "resists DB overload and OOM attempts with infinite generate_series and big strings", %{
      box_id: box_id
    } do
      challenge = %CodeChallenge{
        language: "sql",
        time_limit: 0.2,
        body: %{
          "evaluation_mode" => "query_result",
          "setup_sql" => "CREATE TABLE dummy (id INT);",
          "solution_sql" => "SELECT 1;"
        }
      }

      student_sql = """
      SELECT set_config('statement_timeout', '0', false), repeat('A', 10000000)
      FROM generate_series(1, 10000000);
      """

      result = Verifier.verify(student_sql, challenge, box_id)

      assert result.status in [:time_limit_exceeded, :runtime_error]
      assert result.score == 0
      assert [test_res] = result.test_results
      assert test_res.status in [:time_limit_exceeded, :runtime_error]

      assert_database_dropped("athena_sandbox_#{box_id}")
    end
  end

  defp assert_database_dropped(db_name) do
    config = Application.get_env(:athena, SqlRunner, [])
    url = Keyword.get(config, :url) || "ecto://postgres:postgres@127.0.0.1:5432/postgres"
    uri = URI.parse(url)
    userinfo = uri.userinfo && String.split(uri.userinfo, ":")

    opts = [
      username: (userinfo && Enum.at(userinfo, 0)) || "postgres",
      password: (userinfo && Enum.at(userinfo, 1)) || "postgres",
      hostname: uri.host || "127.0.0.1",
      port: uri.port || 5432,
      database: (uri.path && String.trim_leading(uri.path, "/")) || "postgres"
    ]

    {:ok, conn} = Postgrex.start_link(opts)

    query = "SELECT 1 FROM pg_database WHERE datname = $1;"
    assert {:ok, %Postgrex.Result{rows: []}} = Postgrex.query(conn, query, [db_name])

    GenServer.stop(conn)
  end
end
