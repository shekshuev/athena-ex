defmodule Athena.Execution.VerifierTest do
  use ExUnit.Case, async: true

  alias Athena.Content.CodeChallenge
  alias Athena.Content.TestCase
  alias Athena.Execution.Verifier

  setup do
    box_id = System.unique_integer([:positive, :monotonic]) |> rem(1000)

    python_challenge = %CodeChallenge{
      language: "python3",
      time_limit: 1.0,
      memory_limit: 65_536,
      test_cases: [
        %TestCase{input: "A", expected_output: "A_out", weight: 50},
        %TestCase{input: "B", expected_output: "B_out", weight: 50}
      ]
    }

    cpp_challenge = %CodeChallenge{
      language: "cpp",
      time_limit: 1.0,
      memory_limit: 65_536,
      test_cases: [
        %TestCase{input: "10 20", expected_output: "30", weight: 40},
        %TestCase{input: "5 -5", expected_output: "0", weight: 60}
      ]
    }

    sql_query_challenge = %CodeChallenge{
      language: "sql",
      time_limit: 2.0,
      evaluation_mode: "query_result",
      setup_sql:
        "CREATE TABLE users (id INT, name TEXT); INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob');",
      solution_code: "SELECT * FROM users ORDER BY id;"
    }

    sql_state_challenge = %CodeChallenge{
      language: "sql",
      time_limit: 2.0,
      evaluation_mode: "state_verification",
      setup_sql: "CREATE TABLE items (id INT, active BOOL); INSERT INTO items VALUES (1, false);",
      check_sql:
        "SELECT CASE WHEN count(*) = 0 THEN 'OK' ELSE 'Not all active' END FROM items WHERE NOT active;"
    }

    %{
      python_challenge: python_challenge,
      cpp_challenge: cpp_challenge,
      sql_query_challenge: sql_query_challenge,
      sql_state_challenge: sql_state_challenge,
      box_id: box_id
    }
  end

  describe "Python Verification" do
    @describetag :isolate

    test "returns :accepted and full score for correct code", %{
      python_challenge: challenge,
      box_id: box_id
    } do
      code = "import sys; i = sys.stdin.read().strip(); print(i + '_out')"

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :accepted
      assert result.score == 100
      assert length(result.test_results) == 2
    end

    test "returns :wrong_answer and partial score if one test fails", %{
      python_challenge: challenge,
      box_id: box_id
    } do
      code = "print('A_out')"

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :wrong_answer
      assert result.score == 50
    end

    test "returns :time_limit_exceeded for infinite loops", %{
      python_challenge: challenge,
      box_id: box_id
    } do
      fast_challenge = %{challenge | time_limit: 0.1}
      code = "while True: pass"

      result = Verifier.verify(code, fast_challenge, box_id)

      assert result.status == :time_limit_exceeded
      assert result.score == 0
    end
  end

  describe "C++ Verification (Compile Once, Run Many)" do
    @describetag :isolate

    test "compiles successfully and passes multiple test cases", %{
      cpp_challenge: challenge,
      box_id: box_id
    } do
      code = """
      #include <iostream>
      using namespace std;
      int main() {
          int a, b;
          if (cin >> a >> b) {
              cout << a + b << endl;
          }
          return 0;
      }
      """

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :accepted
      assert result.score == 100
      assert length(result.test_results) == 2

      assert Enum.all?(result.test_results, &(&1.status == :accepted))
    end

    test "fails immediately on Compilation Error (CE) without running tests", %{
      cpp_challenge: challenge,
      box_id: box_id
    } do
      code = "int main() { i am not cpp code }"

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :compilation_error
      assert result.score == 0

      assert length(result.test_results) == 1
      assert hd(result.test_results).status == :compilation_error
      assert hd(result.test_results).stderr =~ "error"
    end
  end

  describe "SQL Verification (Query Result Mode)" do
    test "returns :accepted with columns & rows JSON payload on matching SELECT", %{
      sql_query_challenge: challenge,
      box_id: box_id
    } do
      code = "SELECT * FROM users ORDER BY id;"

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :accepted
      assert result.score == 100
      assert length(result.test_results) == 1

      tr = hd(result.test_results)
      payload = Jason.decode!(tr.stdout)

      assert payload["type"] == "sql_query"
      assert payload["status"] == "accepted"
      assert payload["columns"] == ["id", "name"]
      assert payload["rows"] == [[1, "Alice"], [2, "Bob"]]
      assert payload["expected_columns"] == ["id", "name"]
      assert payload["expected_rows"] == [[1, "Alice"], [2, "Bob"]]
    end

    test "returns :wrong_answer with student vs expected output when results differ", %{
      sql_query_challenge: challenge,
      box_id: box_id
    } do
      code = "SELECT * FROM users WHERE id = 1;"

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :wrong_answer
      assert result.score == 0

      tr = hd(result.test_results)
      payload = Jason.decode!(tr.stdout)

      assert payload["type"] == "sql_query"
      assert payload["status"] == "wrong_answer"
      assert payload["rows"] == [[1, "Alice"]]
      assert payload["expected_rows"] == [[1, "Alice"], [2, "Bob"]]
    end

    test "returns :runtime_error with Postgres error on syntax error in student SQL", %{
      sql_query_challenge: challenge,
      box_id: box_id
    } do
      code = "SELECT non_existing_column FROM users;"

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :runtime_error
      assert result.score == 0

      tr = hd(result.test_results)
      payload = Jason.decode!(tr.stdout)

      assert payload["type"] == "sql_query"
      assert payload["status"] == "sql_error"
      assert payload["stderr"] =~ "column \"non_existing_column\" does not exist"
    end
  end

  describe "SQL Verification (row order)" do
    @heights_setup """
    CREATE TABLE recruits (id SERIAL PRIMARY KEY, name TEXT, height_cm INT);
    INSERT INTO recruits (name, height_cm) VALUES
      ('a', 170), ('b', NULL), ('c', 190), ('d', 180), ('e', NULL);
    """

    defp sql_challenge(attrs) do
      struct!(
        %CodeChallenge{language: "sql", time_limit: 2.0, evaluation_mode: "query_result"},
        attrs
      )
    end

    test "unordered SELECT is rejected when the solution has ORDER BY", %{box_id: box_id} do
      challenge =
        sql_challenge(
          setup_sql: @heights_setup,
          solution_code: "SELECT * FROM recruits ORDER BY height_cm DESC NULLS LAST, id"
        )

      assert Verifier.verify("SELECT * FROM recruits", challenge, box_id).status == :wrong_answer

      assert Verifier.verify(
               "SELECT * FROM recruits ORDER BY height_cm DESC",
               challenge,
               box_id
             ).status == :wrong_answer

      assert Verifier.verify(
               "SELECT * FROM recruits ORDER BY height_cm DESC NULLS LAST, id",
               challenge,
               box_id
             ).status == :accepted
    end

    test "row order is ignored when the solution has no ORDER BY", %{box_id: box_id} do
      challenge =
        sql_challenge(setup_sql: @heights_setup, solution_code: "SELECT * FROM recruits")

      result =
        Verifier.verify("SELECT * FROM recruits ORDER BY name DESC", challenge, box_id)

      assert result.status == :accepted
    end

    test "result_order overrides the auto-detection", %{box_id: box_id} do
      ignore =
        sql_challenge(
          setup_sql: @heights_setup,
          solution_code: "SELECT * FROM recruits ORDER BY id",
          result_order: "ignore"
        )

      strict =
        sql_challenge(
          setup_sql: @heights_setup,
          solution_code: "SELECT * FROM recruits",
          result_order: "strict"
        )

      code = "SELECT * FROM recruits ORDER BY id DESC"

      assert Verifier.verify(code, ignore, box_id).status == :accepted
      assert Verifier.verify(code, strict, box_id).status == :wrong_answer
    end

    test "ORDER BY RANDOM() is reproducible between solution and student query", %{
      box_id: box_id
    } do
      challenge =
        sql_challenge(
          setup_sql: """
          CREATE TABLE t (id INT);
          INSERT INTO t SELECT generate_series(1, 500);
          """,
          solution_code: "SELECT id FROM t ORDER BY RANDOM() LIMIT 2"
        )

      result = Verifier.verify("SELECT id FROM t ORDER BY RANDOM() LIMIT 2", challenge, box_id)

      assert result.status == :accepted
      payload = Jason.decode!(hd(result.test_results).stdout)
      assert length(payload["rows"]) == 2
    end
  end

  describe "SQL Verification (value types)" do
    test "accepts AGE() / interval results", %{box_id: box_id} do
      query = """
      SELECT name, AGE('1696-02-01'::DATE, keel_laid_date) AS current_age
      FROM ships
      WHERE AGE('1696-02-01'::DATE, keel_laid_date) > INTERVAL '2 months'
      """

      challenge =
        sql_challenge(
          setup_sql: """
          CREATE TABLE ships (name TEXT, keel_laid_date DATE);
          INSERT INTO ships VALUES ('Apostol', '1695-06-15'), ('Novy', '1696-01-20');
          """,
          solution_code: query
        )

      result = Verifier.verify(query, challenge, box_id)

      assert result.status == :accepted
      payload = Jason.decode!(hd(result.test_results).stdout)
      assert payload["rows"] == [["Apostol", "7 mons 16 days"]]
    end

    test "does not crash on json, uuid, arrays and bytea columns", %{box_id: box_id} do
      query =
        "SELECT '{\"a\": 1}'::jsonb AS j, gen_random_uuid() IS NOT NULL AS u, " <>
          "ARRAY[1, 2] AS arr, '\\xdeadbeef'::bytea AS b, " <>
          "'00000000-0000-0000-0000-000000000001'::uuid AS id"

      challenge = sql_challenge(setup_sql: nil, solution_code: query)

      result = Verifier.verify(query, challenge, box_id)

      assert result.status == :accepted
      payload = Jason.decode!(hd(result.test_results).stdout)

      assert payload["rows"] == [
               [~s({"a":1}), true, "{1,2}", "\\xdeadbeef", "\\x00000000000000000000000000000001"]
             ]
    end
  end

  describe "SQL Verification (State Verification Mode)" do
    test "returns :accepted on successful state verification", %{
      sql_state_challenge: challenge,
      box_id: box_id
    } do
      code = "UPDATE items SET active = true WHERE id = 1;"

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :accepted
      assert result.score == 100

      tr = hd(result.test_results)
      payload = Jason.decode!(tr.stdout)

      assert payload["type"] == "sql_state"
      assert payload["status"] == "accepted"
      assert payload["message"] == "State verification passed."
    end

    test "returns :wrong_answer with custom check error message on failed state", %{
      sql_state_challenge: challenge,
      box_id: box_id
    } do
      code = "SELECT 1;"

      result = Verifier.verify(code, challenge, box_id)

      assert result.status == :wrong_answer
      assert result.score == 0

      tr = hd(result.test_results)
      payload = Jason.decode!(tr.stdout)

      assert payload["type"] == "sql_state"
      assert payload["status"] == "wrong_answer"
      assert payload["message"] == "Not all active"
    end
  end
end
