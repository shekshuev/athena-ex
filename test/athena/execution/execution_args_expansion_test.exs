defmodule Athena.Execution.ExecutionArgsExpansionTest do
  use ExUnit.Case, async: true

  alias Athena.Execution.{IsolateRunner, LanguageConfig}

  for language <- ~w(go javascript typescript java kotlin csharp c cpp swift rust zig python3) do
    test "#{language} applies the exact task memory limit without managed address-space caps" do
      args = args(unquote(language), 131_072)
      assert Enum.count(args, &(&1 == "--cg-mem=131072")) == 1

      if unquote(language) in ~w(go swift javascript typescript java kotlin csharp) do
        refute "-m" in args
      else
        assert value_after(args, "-m") == "131072"
      end

      assert value_after(args, "-M") == "/tmp/meta with spaces.txt"
      assert value_after(args, "-t") == "2.0"
      assert value_after(args, "-w") == "3.0"
      assert value_after(args, "-f") == "1024"
      assert "-p64" in args
      assert "--cg" in args
      assert "LANG=en_US.UTF-8" in args
      assert "LC_ALL=en_US.UTF-8" in args
      assert value_after(args, "-i") == "stdin.txt"
      assert value_after(args, "-o") == "stdout.txt"
      assert value_after(args, "-r") == "stderr.txt"
    end
  end

  for memory <- [65_536, 131_072, 262_144] do
    test "runtime heaps use half of #{memory} KiB with runtime-specific units" do
      memory = unquote(memory)

      for language <- ~w(javascript typescript) do
        assert "NODE_OPTIONS=--max-old-space-size=#{div(memory, 2048)}" in args(language, memory)
      end

      heap = Integer.to_string(div(memory * 1024, 2), 16)
      assert "DOTNET_GCHeapHardLimit=#{heap}" in args("csharp", memory)
      assert "DOTNET_EnableDiagnostics=0" in args("csharp", memory)
      assert "DOTNET_EnableWriteXorExecute=0" in args("csharp", memory)

      for language <- ~w(java kotlin) do
        argv = args(language, memory) |> Enum.drop_while(&(&1 != "--")) |> tl()
        assert "-Xmx#{div(memory, 2)}k" in argv
        refute Enum.any?(argv, &String.contains?(&1, "{heap_kib}"))
      end
    end
  end

  test "execution command preserves argv boundaries" do
    config = %{
      LanguageConfig.get("python3")
      | run_cmd: ["/tool with spaces/python", "source with spaces.py", "$(touch nope)"]
    }

    ctx = %IsolateRunner.Context{
      box_id: 555,
      lang_config: config,
      time_limit: 2.0,
      memory_limit: 65_536
    }

    argv =
      IsolateRunner.execution_args(ctx, "/tmp/meta") |> Enum.drop_while(&(&1 != "--")) |> tl()

    assert argv == config.run_cmd
  end

  defp args(language, memory) do
    IsolateRunner.execution_args(
      %IsolateRunner.Context{
        box_id: 555,
        lang_config: LanguageConfig.get(language),
        time_limit: 2.0,
        memory_limit: memory
      },
      "/tmp/meta with spaces.txt"
    )
  end

  defp value_after(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)
end
