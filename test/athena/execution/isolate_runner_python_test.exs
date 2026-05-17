defmodule Athena.Execution.IsolateRunnerPythonTest do
  use ExUnit.Case, async: true

  @moduletag :isolate

  alias Athena.Execution.IsolateRunner
  alias Athena.Execution.LanguageConfig

  setup do
    box_id = System.unique_integer([:positive, :monotonic]) |> rem(1000)

    ctx = %IsolateRunner.Context{
      box_id: box_id,
      lang_config: LanguageConfig.get("python3"),
      time_limit: 1.0,
      memory_limit: 65_536
    }

    %{ctx: ctx}
  end

  describe "Happy Paths" do
    test "successfully executes python code and captures stdout", %{ctx: ctx} do
      code = "import sys; print('Test output: ' + sys.stdin.read())"
      input = "Hello World"

      assert {:ok, result} = IsolateRunner.run_test(code, input, ctx)
      assert result.stdout == "Test output: Hello World"
      assert result.meta["exitcode"] == "0"
      assert result.meta["status"] == nil
    end

    test "handles unicode and math correctly", %{ctx: ctx} do
      code = "print('Hi, 🌍! 2 + 2 =', 2+2)"

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)
      assert result.stdout == "Hi, 🌍! 2 + 2 = 4"
      assert result.meta["exitcode"] == "0"
    end
  end

  describe "Error Handling" do
    test "returns non-zero exitcode on SyntaxError", %{ctx: ctx} do
      code = "print('forgot closing quote)"

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)
      assert result.meta["exitcode"] == "1"
      assert result.meta["status"] == "RE"
      assert result.stderr =~ "SyntaxError"
    end

    test "catches Runtime Error (Division by Zero)", %{ctx: ctx} do
      code = "print(10 / 0)"

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)
      assert result.meta["exitcode"] == "1"
      assert result.meta["status"] == "RE"
      assert result.stderr =~ "ZeroDivisionError"
    end

    test "catches Time Limit Exceeded (TLE)", %{ctx: ctx} do
      fast_ctx = %{ctx | time_limit: 0.1}
      code = "while True: pass"

      assert {:ok, result} = IsolateRunner.run_test(code, nil, fast_ctx)
      assert result.meta["status"] == "TO"
    end

    test "catches Memory Limit Exceeded (MLE / OOM)", %{ctx: ctx} do
      tight_mem_ctx = %{ctx | memory_limit: 16_384}
      code = "a = ' ' * (100 * 1024 * 1024)"

      assert {:ok, result} = IsolateRunner.run_test(code, nil, tight_mem_ctx)
      assert result.meta["status"] in ["SG", "RE"]

      assert String.to_integer(result.meta["cg-mem"]) > 10_000
    end
  end

  describe "Security & Penetration Testing" do
    test "prevents reading sensitive system files", %{ctx: ctx} do
      code = """
      try:
          with open('/etc/passwd', 'r') as f:
              print(f.read())
      except Exception as e:
          print("ACCESS DENIED:", type(e).__name__)
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)
      assert result.stdout == "ACCESS DENIED: FileNotFoundError"
      assert result.meta["exitcode"] == "0"
    end

    test "prevents network access (No internet)", %{ctx: ctx} do
      code = """
      import urllib.request
      try:
          urllib.request.urlopen('http://google.com', timeout=1)
          print("HACKED")
      except Exception as e:
          print("NETWORK BLOCKED:", type(e).__name__)
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)
      assert result.stdout =~ "NETWORK BLOCKED: URLError"
    end

    test "prevents arbitrary shell command execution", %{ctx: ctx} do
      code = """
      import subprocess
      try:
          result = subprocess.run(['ls', '-la', '/'], capture_output=True, text=True)
          print(result.stdout)
      except Exception as e:
          print("SHELL BLOCKED:", type(e).__name__)
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)

      refute result.stdout =~ "root"
      refute result.stdout =~ "home"
    end

    test "survives a fork bomb attempt", %{ctx: ctx} do
      code = """
      import os
      import time
      while True:
          try:
              os.fork()
          except OSError:
              time.sleep(0.1)
      """

      fast_ctx = %{ctx | time_limit: 0.2}

      assert {:ok, result} = IsolateRunner.run_test(code, nil, fast_ctx)

      assert result.meta["status"] in ["TO", "RE", "SG"]
    end

    test "catches Output Bomb (File Size Limit Exceeded)", %{ctx: ctx} do
      code = "while True: print('A' * 10000)"

      fast_ctx = %{ctx | time_limit: 0.5}

      assert {:ok, result} = IsolateRunner.run_test(code, nil, fast_ctx)

      assert result.meta["status"] in ["SG", "RE", "TO"]

      assert byte_size(result.stdout) <= 1024 * 1024 + 1000
    end

    test "prevents filling up disk space (Disk Exhaustion)", %{ctx: ctx} do
      code = """
      with open('big_file.txt', 'w') as f:
          while True:
              f.write('A' * 1000000)
      """

      assert {:ok, result} = IsolateRunner.run_test(code, nil, ctx)

      assert result.meta["status"] in ["SG", "RE", "TO"]
    end
  end
end
