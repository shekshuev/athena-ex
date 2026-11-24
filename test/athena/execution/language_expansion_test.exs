defmodule Athena.Execution.LanguageExpansionTest do
  use ExUnit.Case, async: true

  alias Athena.Execution.LanguageConfig

  @families %{
    "python3" => :script,
    "cpp" => :compiled,
    "c" => :compiled,
    "javascript" => :script,
    "typescript" => :script,
    "go" => :compiled,
    "swift" => :compiled,
    "rust" => :compiled,
    "zig" => :compiled,
    "java" => :jvm,
    "kotlin" => :jvm,
    "csharp" => :dotnet,
    "sql" => :db
  }

  test "editor options expose exactly the executable languages, including SQL" do
    options = LanguageConfig.options()
    assert length(options) == 13
    assert MapSet.new(Enum.map(options, &elem(&1, 1))) == MapSet.new(Map.keys(@families))
    assert Enum.all?(options, fn {label, _} -> is_binary(label) and label != "" end)
    assert LanguageConfig.default_language() == "python3"
    assert LanguageConfig.get("unsupported") == nil
  end

  for {language, family} <- @families do
    test "#{language} has its expected dispatch family and argv commands" do
      config = LanguageConfig.get(unquote(language))
      assert config.family == unquote(family)
      assert is_binary(config.source_file)
      assert is_list(config.run_cmd)
      assert Enum.all?(config.run_cmd, &is_binary/1)

      if config.compile_cmd do
        assert [command | _] = config.compile_cmd
        assert String.starts_with?(command, "/")
        assert Enum.all?(config.compile_cmd, &is_binary/1)
      end

      if unquote(family) != :db, do: assert(config.run_cmd != [])
    end
  end

  test "legacy external language identifiers remain stable" do
    assert LanguageConfig.get("python3").id == 71
    assert LanguageConfig.get("cpp").id == 54
    assert LanguageConfig.get("sql").id == 82
  end

  test "C++ retains its compilation command and original compilation budget" do
    config = LanguageConfig.get("cpp")
    assert config.compile_cmd == ["/usr/bin/g++", "-O3", "main.cpp", "-o", "out"]
    assert config.compile_time == 10.0
    assert config.compile_wall_time == 12.0
    assert config.compile_memory == 262_144
    assert config.compile_memory_mode == :address_space
  end
end
