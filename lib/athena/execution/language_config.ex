defmodule Athena.Execution.LanguageConfig do
  @moduledoc """
  Provides configuration for supported programming languages.
  Defines execution commands and source file names.
  """

  defstruct [
    :id,
    :name,
    :source_file,
    :compile_cmd,
    :run_cmd,
    :family,
    compile_env: %{},
    compile_time: 10.0,
    compile_wall_time: 12.0,
    compile_memory: 262_144,
    compile_memory_mode: :address_space,
    compile_file_size: 10_240,
    runtime_memory: :address_space
  ]

  @type family :: :db | :compiled | :script | :jvm | :dotnet
  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          source_file: String.t(),
          compile_cmd: [String.t()] | nil,
          run_cmd: [String.t()],
          family: family(),
          compile_env: %{String.t() => String.t()},
          compile_time: float(),
          compile_wall_time: float(),
          compile_memory: pos_integer(),
          compile_memory_mode: :address_space | :cgroup,
          compile_file_size: pos_integer(),
          runtime_memory: :address_space | :cgroup
        }

  # Toolchain patch versions are pinned in the runner images, not in persisted tasks.
  @languages [
    {"python3", "Python", "script.py", nil, ["python3", "script.py"], :script},
    {"cpp", "C++", "main.cpp", ["g++", "-O3", "main.cpp", "-o", "out"], ["./out"], :compiled},
    {"c", "C", "main.c", ["gcc", "-std=c17", "-O2", "main.c", "-o", "out", "-lm"], ["./out"],
     :compiled},
    {"javascript", "JavaScript (Node.js 26 LTS)", "main.js", nil, ["node", "main.js"], :script},
    {"typescript", "TypeScript", "main.ts",
     [
       "tsc",
       "--strict",
       "--noEmitOnError",
       "--target",
       "ES2022",
       "--module",
       "node16",
       "--moduleResolution",
       "node16",
       "--typeRoots",
       "{node_types}",
       "--types",
       "node",
       "main.ts"
     ], ["node", "main.js"], :script},
    {"go", "Go", "main.go", ["go", "build", "-trimpath", "-o", "out", "main.go"], ["./out"],
     :compiled},
    {"swift", "Swift", "main.swift",
     [
       "swiftc",
       "-swift-version",
       "6",
       "-O",
       "-module-cache-path",
       "/box/.cache/swift",
       "-Xlinker",
       "-rpath",
       "-Xlinker",
       "{swift_runtime}",
       "main.swift",
       "-o",
       "out"
     ], ["./out"], :compiled},
    {"rust", "Rust", "main.rs",
     [
       "rustc",
       "--edition=2024",
       "-C",
       "linker={gcc}",
       "-O",
       "main.rs",
       "-o",
       "out"
     ], ["./out"], :compiled},
    {"zig", "Zig", "main.zig",
     ["zig", "build-exe", "-j1", "main.zig", "-lc", "-O", "ReleaseSafe", "-femit-bin=out"],
     ["./out"], :compiled},
    {"java", "Java (21)", "Main.java",
     [
       "javac",
       "-J-Xmx512m",
       "-J-XX:ActiveProcessorCount=2",
       "--release",
       "21",
       "Main.java"
     ],
     [
       "java",
       "-XX:ActiveProcessorCount=1",
       "-XX:+UseSerialGC",
       "-Xms8m",
       "-Xmx{heap_kib}k",
       "Main"
     ], :jvm},
    {"kotlin", "Kotlin (JVM 21)", "Main.kt",
     [
       "kotlinc",
       "-J-Xmx512m",
       "-J-XX:ActiveProcessorCount=2",
       "-jvm-target",
       "21",
       "Main.kt",
       "-include-runtime",
       "-d",
       "main.jar"
     ],
     [
       "java",
       "-XX:ActiveProcessorCount=1",
       "-XX:+UseSerialGC",
       "-Xms8m",
       "-Xmx{heap_kib}k",
       "-jar",
       "main.jar"
     ], :jvm},
    {"csharp", "C# (.NET 10 LTS)", "Main.cs",
     [
       "dotnet",
       "{csc}",
       "-nologo",
       "-noconfig",
       "-nostdlib+",
       "-target:exe",
       "-langversion:14.0",
       "-optimize+",
       "-deterministic+",
       "-out:out/Main.dll",
       "@references.rsp",
       "ImplicitUsings.g.cs",
       "Main.cs"
     ], ["dotnet", "out/Main.dll"], :dotnet},
    {"sql", "SQL", "query.sql", nil, [], :db}
  ]

  @doc "Returns a language configuration, or nil for an unsupported identifier."
  @spec get(String.t()) :: t() | nil
  def get(language) do
    case Enum.find(@languages, fn {id, _, _, _, _, _} -> id == language end) do
      nil ->
        nil

      {id, name, source, compile, run, family} ->
        %__MODULE__{
          id: legacy_id(id),
          name: name,
          source_file: source,
          compile_cmd: compile,
          run_cmd: run,
          family: family
        }
        |> compilation_profile(id)
        |> memory_profile(id)
    end
  end

  defp legacy_id("python3"), do: 71
  defp legacy_id("cpp"), do: 54
  defp legacy_id("sql"), do: 82
  defp legacy_id(_), do: nil

  defp compilation_profile(config, id)
       when id in ~w(go swift rust zig java kotlin csharp typescript) do
    %{
      config
      | compile_time: 60.0,
        compile_wall_time: 120.0,
        compile_memory: 1_048_576,
        compile_memory_mode: :cgroup,
        compile_file_size: 131_072
    }
  end

  defp compilation_profile(config, _), do: config

  defp memory_profile(config, id)
       when id in ~w(go swift javascript typescript java kotlin csharp) do
    %{config | runtime_memory: :cgroup}
  end

  defp memory_profile(config, _), do: config

  @doc "Returns languages available for explicit selection in the editor."
  def options, do: Enum.map(@languages, fn {id, name, _, _, _, _} -> {name, id} end)

  @doc "Returns the default language identifier for new tasks."
  def default_language, do: "python3"

  @doc false
  def run_command(config, memory_limit) do
    heap_kib = max(div(memory_limit, 2), 256)
    Enum.map(config.run_cmd, &String.replace(&1, "{heap_kib}", to_string(heap_kib)))
  end

  @runtime_versions %{
    "python3" => "CPython 3.11.x (Debian)",
    "c" => "GCC 12.x (Debian)",
    "cpp" => "GCC 12.x (Debian)",
    "javascript" => "Node.js 26.13.1 LTS",
    "typescript" => "TypeScript 7.0.2 · Node.js 26.13.1 LTS",
    "go" => "Go 1.27.4",
    "swift" => "Swift 6.4.3 · Swift 6 mode",
    "rust" => "Rust 1.100.0 · edition 2024",
    "zig" => "Zig 0.17.1",
    "java" => "Temurin 21.0.13.1+2 · Java 21",
    "kotlin" => "Kotlin 2.4.21 · JVM 21",
    "csharp" => "C# 14 · .NET SDK 10.0.404"
  }

  @doc "Describes the configured runner image and commands, without probing the web host."
  def runtime_info(language, memory_limit \\ 65_536) do
    case get(language) do
      %__MODULE__{family: family} = config when family != :db ->
        %{
          version: Map.fetch!(@runtime_versions, language),
          source: config.source_file,
          compile: display_command(config.compile_cmd),
          run: config |> run_command(memory_limit) |> display_command(),
          compile_time: config.compile_time,
          compile_memory: div(config.compile_memory, 1024)
        }

      _ ->
        nil
    end
  end

  defp display_command(nil), do: nil

  defp display_command(args) do
    args
    |> Enum.map(
      &(&1
        |> String.replace("{node_types}", "<Node types>")
        |> String.replace("{swift_runtime}", "<Swift runtime>")
        |> String.replace("{gcc}", "gcc")
        |> String.replace("{csc}", "<SDK>/Roslyn/bincore/csc.dll"))
    )
    |> Enum.join(" ")
  end

  # {backend language identifier, CodeMirror mode, display label}
  @cm_languages [
    {"python3", "python", "Python"},
    {"cpp", "cpp", "C++"},
    {"c", "c", "C"},
    {"csharp", "csharp", "C#"},
    {"typescript", "typescript", "TypeScript"},
    {"kotlin", "kotlin", "Kotlin"},
    {"swift", "swift", "Swift"},
    {"zig", "zig", "Zig"},
    {"java", "java", "Java"},
    {"go", "go", "Go"},
    {"rust", "rust", "Rust"},
    {"php", "php", "PHP"},
    {"javascript", "javascript", "JS"},
    {"sql", "sql", "SQL"},
    {"html", "html", "HTML"},
    {"css", "css", "CSS"},
    {"xml", "xml", "XML"},
    {"json", "json", "JSON"},
    {"markdown", "markdown", "MD"},
    {"yaml", "yaml", "YAML"}
  ]

  @doc """
  Maps backend language identifiers to CodeMirror language modes.
  """
  @spec cm_lang(String.t()) :: String.t()
  for {backend_id, cm_mode, _label} <- @cm_languages do
    def cm_lang(unquote(backend_id)), do: unquote(cm_mode)
  end

  def cm_lang(_), do: "python"

  # Languages a Tiptap code block can be *highlighted* as but the runner
  # cannot execute, so they stay out of `@cm_languages` (which drives
  # `cm_lang/1` for the CodeMirror editor in runnable code blocks).
  # `plaintext` and `bash` come with lowlight's `common` bundle; `powershell`
  # is registered explicitly in app.js.
  @highlight_only_languages [
    {"plaintext", "Text"},
    {"bash", "Bash"},
    {"powershell", "PowerShell"}
  ]

  @doc """
  Returns `{cm_mode, label}` pairs for every supported CodeMirror language,
  for UI pickers such as the Tiptap code-block language switcher.
  """
  @spec cm_languages() :: [{String.t(), String.t()}]
  def cm_languages, do: Enum.map(@cm_languages, fn {_id, cm_mode, label} -> {cm_mode, label} end)

  @doc """
  Returns `{highlight mode, label}` pairs for the Tiptap code-block language
  picker: every runnable language plus the highlight-only ones.
  """
  @spec tiptap_languages() :: [{String.t(), String.t()}]
  def tiptap_languages, do: cm_languages() ++ @highlight_only_languages
end
