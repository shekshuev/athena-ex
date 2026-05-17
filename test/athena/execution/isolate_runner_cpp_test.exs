defmodule Athena.Execution.IsolateRunnerCppTest do
  use ExUnit.Case, async: true

  @moduletag :isolate

  alias Athena.Execution.IsolateRunner
  alias Athena.Execution.LanguageConfig

  setup do
    box_id = System.unique_integer([:positive, :monotonic]) |> rem(1000)

    ctx = %IsolateRunner.Context{
      box_id: box_id,
      lang_config: LanguageConfig.get("cpp"),
      time_limit: 1.0,
      memory_limit: 65_536
    }

    %{ctx: ctx}
  end

  describe "Happy Paths & Compilation" do
    test "successfully compiles and executes C++ code", %{ctx: ctx} do
      code = """
      #include <iostream>
      #include <string>
      using namespace std;

      int main() {
          string input;
          getline(cin, input);
          cout << "Test output: " << input << endl;
          return 0;
      }
      """

      assert {:ok, result} = IsolateRunner.run_test(code, "Hello World", ctx)
      assert result.stdout == "Test output: Hello World"
      assert result.meta["exitcode"] == "0"
      assert result.meta["status"] == nil
    end

    test "handles Compilation Error (CE)", %{ctx: ctx} do
      code = """
      #include <iostream>
      int main() {
          std::cout << "I am missing something"
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)

      assert result.meta["status"] == "CE"
      assert result.stdout == ""
      assert result.stderr =~ "error:"
    end
  end

  describe "Runtime Errors & Limits" do
    test "catches Segfault (SIGSEGV)", %{ctx: ctx} do
      code = """
      int main() {
          int *ptr = nullptr;
          *ptr = 42;
          return 0;
      }
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)

      assert result.meta["status"] == "SG"
      assert result.meta["exitsig"] == "11"
    end

    test "catches Time Limit Exceeded (TLE)", %{ctx: ctx} do
      fast_ctx = %{ctx | time_limit: 0.1}

      code = """
      int main() {
          while(true) {}
          return 0;
      }
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, fast_ctx)
      assert result.meta["status"] == "TO"
    end

    test "catches Memory Limit Exceeded (MLE)", %{ctx: ctx} do
      code = """
      #include <iostream>
      #include <vector>

      int main() {
          std::vector<int>* huge = new std::vector<int>(100000000, 1);
          std::cout << huge->at(42) << std::endl;
          return 0;
      }
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)

      assert result.meta["status"] in ["SG", "RE"]

      if result.meta["cg-mem"] do
        assert String.to_integer(result.meta["cg-mem"]) > 50_000
      end
    end
  end

  describe "Security Vectors in C++" do
    test "prevents execution of system commands (Shell Injection)", %{ctx: ctx} do
      code = """
      #include <cstdlib>
      #include <iostream>
      int main() {
          int sys_res = system("cat /etc/passwd");
          std::cout << "Sys exit: " << sys_res << std::endl;
          return 0;
      }
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)
      refute result.stdout =~ "root:x:0:0"
    end

    test "prevents direct file system reads", %{ctx: ctx} do
      code = """
      #include <iostream>
      #include <fstream>
      #include <string>

      int main() {
          std::ifstream file("/etc/passwd");
          if (file.is_open()) {
              std::string line;
              while (getline(file, line)) std::cout << line << "\\n";
              file.close();
          } else {
              std::cout << "ACCESS DENIED" << std::endl;
          }
          return 0;
      }
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)
      assert result.stdout == "ACCESS DENIED"
    end

    test "survives a C++ Fork Bomb", %{ctx: ctx} do
      code = """
      #include <unistd.h>
      int main() {
          while(true) {
              fork();
          }
          return 0;
      }
      """

      fast_ctx = %{ctx | time_limit: 0.2}
      assert {:ok, result} = IsolateRunner.run_test(code, nil, fast_ctx)
      assert result.meta["status"] in ["TO", "RE", "SG"]
    end

    test "catches Compile-Time Bomb (/dev/random)", %{ctx: ctx} do
      code = """
      #include </dev/random>
      int main() { return 0; }
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)

      assert result.meta["status"] == "CE"
      assert result.stderr =~ "error"
    end

    test "catches C++ Output Bomb", %{ctx: ctx} do
      code = """
      #include <iostream>
      int main() {
          while(true) std::cout << "CRASH_THE_SERVER";
          return 0;
      }
      """

      fast_ctx = %{ctx | time_limit: 0.5}
      assert {:ok, result} = IsolateRunner.run_test(code, nil, fast_ctx)

      assert result.meta["status"] in ["SG", "RE", "TO"]
      assert byte_size(result.stdout) <= 1024 * 1024 + 1000
    end

    test "catches Template Metaprogramming Bomb (Memory exhaustion during compilation)", %{
      ctx: ctx
    } do
      code = """
      template<int N> struct Boom {
          Boom<N - 1> a;
          Boom<N - 1> b;
      };
      template<> struct Boom<0> {};

      int main() {
          Boom<100> boom;
          return 0;
      }
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)

      assert result.meta["status"] == "CE"
      assert result.stderr == "" or result.stderr =~ "error"
    end
  end
end
