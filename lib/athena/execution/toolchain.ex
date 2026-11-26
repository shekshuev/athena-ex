defmodule Athena.Execution.Toolchain do
  @moduledoc """
  Resolves globally installed tools and prepares sandbox-local compiler inputs.
  Commands remain argument vectors; no shell or language launcher is involved.
  """

  alias Athena.Execution.LanguageConfig

  @path "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  @implicit_usings Enum.map_join(
                     ~w(System System.Collections.Generic System.IO System.Linq System.Net.Http System.Threading System.Threading.Tasks),
                     "\n",
                     &"global using global::#{&1};"
                   )

  def path, do: @path

  @spec prepare(LanguageConfig.t(), String.t()) ::
          {:ok, LanguageConfig.t()} | {:error, {:toolchain_unavailable, String.t()}}
  def prepare(config, box_dir) do
    with {:ok, compile} <- resolve(config.compile_cmd),
         {:ok, run} <- resolve(config.run_cmd) do
      configure(%{config | compile_cmd: compile, run_cmd: run}, box_dir)
    end
  rescue
    error in File.Error -> {:error, {:toolchain_unavailable, Exception.message(error)}}
  end

  defp resolve(nil), do: {:ok, nil}
  defp resolve([]), do: {:ok, []}
  defp resolve(["./" <> _ | _] = command), do: {:ok, command}

  defp resolve([command | args]) do
    case find_executable(command) do
      nil -> unavailable("Executable #{command} is not available on the runner PATH")
      executable -> {:ok, [executable | args]}
    end
  end

  # Resolve alternatives links outside the sandbox; /etc is intentionally hidden.
  defp find_executable(command) do
    case :os.find_executable(String.to_charlist(command), String.to_charlist(@path)) do
      false -> nil
      executable -> follow_links(List.to_string(executable), 32)
    end
  end

  defp follow_links(_path, 0), do: nil

  defp follow_links(path, remaining) do
    case File.read_link(path) do
      {:ok, target} ->
        # Swift's multicall driver selects compilation from argv[0]. Keep its
        # vendor swiftc entry point instead of invoking swift-driver by name.
        if Path.basename(path) == "swiftc" and Path.basename(target) == "swift-driver" do
          path
        else
          follow_links(Path.expand(target, Path.dirname(path)), remaining - 1)
        end

      {:error, :einval} ->
        path

      {:error, _} ->
        nil
    end
  end

  defp configure(%{source_file: "main.ts"} = config, _box_dir) do
    [tsc | _] = config.compile_cmd
    types = tsc |> Path.dirname() |> Path.dirname() |> Path.dirname() |> Path.join("@types")

    if File.regular?(Path.join(types, "node/package.json")) do
      {:ok,
       config
       |> substitute("{node_types}", types)
       |> environment(%{"NODE_OPTIONS" => "--max-old-space-size=512"})}
    else
      unavailable(
        "Node type definitions are not installed next to the global TypeScript compiler"
      )
    end
  end

  defp configure(%{source_file: "main.go"} = config, box_dir) do
    directories(box_dir, [".cache", ".cache/go", ".cache/gopath"])

    env = %{
      "GOMAXPROCS" => "2",
      "GOCACHE" => "/box/.cache/go",
      "GOPATH" => "/box/.cache/gopath",
      "GOENV" => "off",
      "GOPROXY" => "off",
      "GOSUMDB" => "off",
      "GOTOOLCHAIN" => "local",
      "CGO_ENABLED" => "0"
    }

    env =
      case find_executable("athena-go-cache") do
        nil -> env
        adapter -> Map.put(env, "GOCACHEPROG", adapter)
      end

    {:ok, environment(config, env)}
  end

  defp configure(%{source_file: "main.swift"} = config, box_dir) do
    directories(box_dir, [".cache", ".cache/swift"])
    [swiftc | _] = config.compile_cmd
    runtime = Path.expand("../lib/swift/linux", Path.dirname(swiftc))
    {:ok, substitute(config, "{swift_runtime}", runtime)}
  end

  defp configure(%{source_file: "main.rs"} = config, _box_dir) do
    case find_executable("gcc") do
      nil -> unavailable("Rust requires a global gcc linker")
      gcc -> {:ok, substitute(config, "{gcc}", gcc)}
    end
  end

  defp configure(%{source_file: "Main.kt"} = config, _box_dir) do
    [java | _] = config.run_cmd
    {:ok, environment(config, %{"JAVA_HOME" => java |> Path.dirname() |> Path.dirname()})}
  end

  defp configure(%{source_file: "main.zig"} = config, box_dir) do
    directories(box_dir, [".cache", ".cache/zig-global", ".cache/zig-local"])

    config =
      environment(config, %{
        "ZIG_GLOBAL_CACHE_DIR" => "/box/.cache/zig-global",
        "ZIG_LOCAL_CACHE_DIR" => "/box/.cache/zig-local"
      })

    # Single-job private caches need no advisory locks. The actual syscall stays
    # blocked by isolate; only the compiler sees a successful no-op, never a lock.
    case find_executable("strace") do
      nil ->
        {:ok, config}

      tracer ->
        {:ok,
         %{
           config
           | compile_cmd: [
               tracer,
               "-f",
               "-qq",
               "-o",
               "/dev/null",
               "-e",
               "trace=flock",
               "-e",
               "inject=flock:retval=0",
               "--" | config.compile_cmd
             ]
         }}
    end
  end

  defp configure(%{source_file: "Main.cs"} = config, box_dir) do
    [dotnet | _] = config.compile_cmd
    root = Path.dirname(dotnet)
    sdk = latest(Path.join(root, "sdk/10.*"))
    references = latest(Path.join(root, "packs/Microsoft.NETCore.App.Ref/10.*"))

    if sdk && references && File.regular?(Path.join(sdk, "Roslyn/bincore/csc.dll")) do
      directories(box_dir, ["out"])
      files = Path.wildcard(Path.join(references, "ref/net10.0/*.dll"))

      if files == [],
        do:
          raise(File.Error,
            reason: :enoent,
            action: "find .NET 10 reference assemblies",
            path: references
          )

      File.write!(
        Path.join(box_dir, "references.rsp"),
        Enum.map_join(files, "\n", &"-r:\"#{&1}\"")
      )

      File.write!(Path.join(box_dir, "ImplicitUsings.g.cs"), @implicit_usings)

      File.write!(
        Path.join(box_dir, "out/Main.runtimeconfig.json"),
        Jason.encode!(%{
          runtimeOptions: %{
            tfm: "net10.0",
            framework: %{name: "Microsoft.NETCore.App", version: "10.0.0"}
          }
        })
      )

      {:ok,
       config
       |> substitute("{csc}", Path.join(sdk, "Roslyn/bincore/csc.dll"))
       |> environment(%{
         "DOTNET_ROOT" => root,
         "DOTNET_PROCESSOR_COUNT" => "2",
         "DOTNET_EnableDiagnostics" => "0"
       })}
    else
      unavailable(
        "The global dotnet installation requires the .NET 10 SDK and reference assemblies"
      )
    end
  end

  defp configure(config, _box_dir), do: {:ok, config}

  defp latest(pattern) do
    pattern
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(fn directory -> {Version.parse(Path.basename(directory)), directory} end)
    |> Enum.filter(fn {version, _} -> match?({:ok, _}, version) end)
    |> Enum.sort(fn {{:ok, a}, _}, {{:ok, b}, _} -> Version.compare(a, b) == :gt end)
    |> List.first()
    |> case do
      nil -> nil
      {_, directory} -> directory
    end
  end

  defp substitute(config, key, value),
    do: %{config | compile_cmd: Enum.map(config.compile_cmd, &String.replace(&1, key, value))}

  defp environment(config, env), do: %{config | compile_env: env}

  defp directories(root, paths) do
    Enum.each(paths, fn path ->
      directory = Path.join(root, path)
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o777)
    end)
  end

  defp unavailable(message), do: {:error, {:toolchain_unavailable, message}}
end
