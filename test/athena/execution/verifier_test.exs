defmodule Athena.Execution.VerifierTest do
  use ExUnit.Case, async: true
  @moduletag :isolate

  alias Athena.Execution.Verifier
  alias Athena.Content.CodeChallenge
  alias Athena.Content.TestCase

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

    %{python_challenge: python_challenge, cpp_challenge: cpp_challenge, box_id: box_id}
  end

  describe "Python Verification" do
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
end
