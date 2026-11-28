defmodule Athena.Execution.ToolchainTest do
  use ExUnit.Case, async: true

  alias Athena.Execution.{LanguageConfig, Toolchain}

  setup do
    root = Path.join(System.tmp_dir!(), "athena-toolchain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "resolves alternatives symlinks and preserves argv without a shell", %{root: root} do
    executable = executable(root, "jdk/bin/java")
    alias_path = Path.join(root, "java")
    File.ln_s!("jdk/bin/java", alias_path)

    config = %{
      LanguageConfig.get("java")
      | compile_cmd: [alias_path, "source with spaces.java"],
        run_cmd: [alias_path, "$(touch forbidden)"]
    }

    assert {:ok, prepared} = Toolchain.prepare(config, root)
    assert prepared.compile_cmd == [executable, "source with spaces.java"]
    assert prepared.run_cmd == [executable, "$(touch forbidden)"]
    refute File.exists?(Path.join(root, "forbidden"))
  end

  test "missing executable returns a useful error before calling isolate", %{root: root} do
    config = %{
      LanguageConfig.get("javascript")
      | run_cmd: [Path.join(root, "missing-node"), "main.js"]
    }

    assert {:error, {:toolchain_unavailable, message}} = Toolchain.prepare(config, root)
    assert message =~ "missing-node"
    assert message =~ "PATH"
  end

  test "TypeScript discovers global Node types next to the resolved compiler", %{root: root} do
    tsc = executable(root, "lib/node_modules/typescript/bin/tsc")
    node = executable(root, "bin/node")
    types = Path.join(root, "lib/node_modules/@types")
    File.mkdir_p!(Path.join(types, "node"))
    File.write!(Path.join(types, "node/package.json"), "{}")

    config = %{
      LanguageConfig.get("typescript")
      | compile_cmd: [tsc, "--typeRoots", "{node_types}", "main.ts"],
        run_cmd: [node, "main.js"]
    }

    assert {:ok, prepared} = Toolchain.prepare(config, root)
    assert prepared.compile_cmd == [tsc, "--typeRoots", types, "main.ts"]
    assert prepared.compile_env["NODE_OPTIONS"] == "--max-old-space-size=512"
  end

  test "TypeScript reports missing Node type definitions", %{root: root} do
    tsc = executable(root, "lib/node_modules/typescript/bin/tsc")
    node = executable(root, "bin/node")

    config = %{
      LanguageConfig.get("typescript")
      | compile_cmd: [tsc, "{node_types}"],
        run_cmd: [node]
    }

    assert {:error, {:toolchain_unavailable, message}} = Toolchain.prepare(config, root)
    assert message =~ "Node type definitions"
  end

  test "Go prepares writable private caches and offline compiler environment", %{root: root} do
    go = executable(root, "go/bin/go")
    config = %{LanguageConfig.get("go") | compile_cmd: [go, "build", "main.go"]}
    assert {:ok, prepared} = Toolchain.prepare(config, root)
    assert prepared.compile_cmd == [go, "build", "main.go"]
    assert prepared.compile_env["GOPROXY"] == "off"
    assert prepared.compile_env["CGO_ENABLED"] == "0"
    assert prepared.compile_env["GOCACHE"] == "/box/.cache/go"

    for path <- [".cache", ".cache/go", ".cache/gopath"] do
      assert {:ok, %{mode: mode}} = File.stat(Path.join(root, path))
      assert Bitwise.band(mode, 0o777) == 0o777
    end
  end

  test "Swift runtime path follows the globally resolved compiler", %{root: root} do
    swiftc = executable(root, "swift/usr/bin/swiftc")

    config = %{
      LanguageConfig.get("swift")
      | compile_cmd: [swiftc, "-rpath", "{swift_runtime}", "main.swift"]
    }

    assert {:ok, prepared} = Toolchain.prepare(config, root)

    assert prepared.compile_cmd == [
             swiftc,
             "-rpath",
             Path.join(root, "swift/usr/lib/swift/linux"),
             "main.swift"
           ]

    assert File.dir?(Path.join(root, ".cache/swift"))
  end

  test "Swift keeps the vendor compiler entry name for its multicall driver", %{root: root} do
    _driver = executable(root, "swift/usr/bin/swift-driver")
    swiftc = Path.join(root, "swift/usr/bin/swiftc")
    File.ln_s!("swift-driver", swiftc)
    global = Path.join(root, "swiftc")
    File.ln_s!(swiftc, global)
    config = %{LanguageConfig.get("swift") | compile_cmd: [global, "main.swift"]}
    assert {:ok, prepared} = Toolchain.prepare(config, root)
    assert prepared.compile_cmd == [swiftc, "main.swift"]
  end

  test "Kotlin receives the resolved JDK home", %{root: root} do
    java = executable(root, "jdk/bin/java")
    kotlin = executable(root, "kotlin/bin/kotlinc")

    config = %{
      LanguageConfig.get("kotlin")
      | compile_cmd: [kotlin, "Main.kt"],
        run_cmd: [java, "-jar", "main.jar"]
    }

    assert {:ok, prepared} = Toolchain.prepare(config, root)
    assert prepared.compile_env["JAVA_HOME"] == Path.join(root, "jdk")
  end

  test "C# selects .NET 10 SDK and prepares Roslyn inputs in Elixir", %{root: root} do
    dotnet = executable(root, "dotnet/dotnet")
    sdk_root = Path.dirname(dotnet)

    for sdk <- ["10.0.100", "10.0.404", "11.0.100"] do
      compiler = Path.join(sdk_root, "sdk/#{sdk}/Roslyn/bincore/csc.dll")
      File.mkdir_p!(Path.dirname(compiler))
      File.write!(compiler, "compiler")
    end

    refs = Path.join(sdk_root, "packs/Microsoft.NETCore.App.Ref/10.0.15/ref/net10.0")
    File.mkdir_p!(refs)
    File.write!(Path.join(refs, "System.Runtime.dll"), "reference")

    config = %{
      LanguageConfig.get("csharp")
      | compile_cmd: [dotnet, "{csc}", "@references.rsp", "Main.cs"],
        run_cmd: [dotnet, "out/Main.dll"]
    }

    assert {:ok, prepared} = Toolchain.prepare(config, root)

    assert Enum.at(prepared.compile_cmd, 1) ==
             Path.join(sdk_root, "sdk/10.0.404/Roslyn/bincore/csc.dll")

    assert File.read!(Path.join(root, "references.rsp")) == "-r:\"#{refs}/System.Runtime.dll\""
    assert File.read!(Path.join(root, "ImplicitUsings.g.cs")) =~ "global using global::System;"
    runtime = root |> Path.join("out/Main.runtimeconfig.json") |> File.read!() |> Jason.decode!()
    assert runtime["runtimeOptions"]["framework"]["version"] == "10.0.0"
    assert prepared.compile_env["DOTNET_ROOT"] == sdk_root
  end

  defp executable(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
