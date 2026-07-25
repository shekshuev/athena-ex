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
      body: %{
        "evaluation_mode" => "query_result",
        "setup_sql" =>
          "CREATE TABLE users (id INT, name TEXT); INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob');",
        "solution_sql" => "SELECT * FROM users ORDER BY id;"
      }
    }

    sql_state_challenge = %CodeChallenge{
      language: "sql",
      time_limit: 2.0,
      body: %{
        "evaluation_mode" => "state_verification",
        "setup_sql" =>
          "CREATE TABLE items (id INT, active BOOL); INSERT INTO items VALUES (1, false);",
        "check_sql" =>
          "SELECT CASE WHEN count(*) = 0 THEN 'OK' ELSE 'Not all active' END FROM items WHERE NOT active;"
      }
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
