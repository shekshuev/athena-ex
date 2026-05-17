defmodule Athena.Execution.IsolateRunner do
  @moduledoc """
  Low-level wrapper around the `isolate` binary.
  Handles sandbox lifecycle: init -> setup -> run -> cleanup.
  """
  require Logger

  @isolate_bin "/usr/bin/isolate"

  defmodule Context do
    @moduledoc """
    Execution context for a single sandbox run.
    """
    defstruct [:box_id, :work_dir, :box_dir, :lang_config, :time_limit, :memory_limit]

    @type t :: %__MODULE__{
            box_id: integer(),
            work_dir: String.t() | nil,
            box_dir: String.t() | nil,
            lang_config: Athena.Execution.LanguageConfig.t(),
            time_limit: float(),
            memory_limit: integer()
          }
  end

  @doc """
  Executes code within the isolated sandbox.
  Initializes the environment, writes necessary files, compiles (if needed), runs the process, and cleans up.
  """
  @spec run_test(String.t(), String.t() | nil, Context.t()) ::
          {:ok, %{meta: map(), stdout: String.t(), stderr: String.t()}} | {:error, atom()}
  def run_test(code, input, %Context{} = ctx) do
    System.cmd(@isolate_bin, ["--cleanup", "--cg", "-b", "#{ctx.box_id}"])

    try do
      with {:ok, ctx} <- init_sandbox(ctx),
           :ok <- write_source(code, ctx),
           :ok <- write_stdin(input, ctx),
           :ok <- compile(ctx),
           {:ok, meta} <- execute(ctx) do
        stdout = read_box_file(ctx, "stdout.txt")
        stderr = read_box_file(ctx, "stderr.txt")

        {:ok, %{meta: meta, stdout: stdout, stderr: stderr}}
      else
        {:error, {:compilation_error, stderr}} ->
          {:ok, %{meta: %{"status" => "CE"}, stdout: "", stderr: stderr}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      cleanup_sandbox(ctx)
    end
  end

  @doc """
  Stage 1: Initializes the sandbox, writes the source code, and compiles it.
  Use this for the "Compile Once" step in test suites.
  """
  @spec setup_sandbox(String.t(), Context.t()) :: {:ok, Context.t()} | {:error, any()}
  def setup_sandbox(code, %Context{} = ctx) do
    System.cmd(@isolate_bin, ["--cleanup", "--cg", "-b", "#{ctx.box_id}"])

    with {:ok, ctx} <- init_sandbox(ctx),
         :ok <- write_source(code, ctx),
         :ok <- compile(ctx) do
      {:ok, ctx}
    end
  end

  @doc """
  Stage 2: Runs the compiled binary with a specific input.
  Can be called multiple times for different test cases.
  """
  @spec run_execution(String.t() | nil, Context.t()) :: {:ok, map()} | {:error, atom()}
  def run_execution(input, %Context{} = ctx) do
    with :ok <- write_stdin(input, ctx),
         {:ok, meta} <- execute(ctx) do
      stdout = read_box_file(ctx, "stdout.txt")
      stderr = read_box_file(ctx, "stderr.txt")
      {:ok, %{meta: meta, stdout: stdout, stderr: stderr}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stage 3: Cleans up the sandbox. Must be called in `after` block.
  """
  @spec cleanup(Context.t()) :: :ok
  def cleanup(%Context{} = ctx) do
    cleanup_sandbox(ctx)
  end

  defp write_source(code, ctx) do
    source_path = Path.join(ctx.box_dir, ctx.lang_config.source_file)
    File.write!(source_path, code)
    :ok
  rescue
    _ -> {:error, :write_failed}
  end

  defp write_stdin(input, ctx) do
    stdin_path = Path.join(ctx.box_dir, "stdin.txt")

    case File.write(stdin_path, input || "") do
      :ok -> :ok
      {:error, _} -> {:error, :write_failed}
    end
  end

  @doc false
  @spec compile(Context.t()) :: :ok | {:error, {:compilation_error, String.t()}}
  defp compile(%Context{lang_config: %{compile_cmd: nil}}), do: :ok

  defp compile(ctx) do
    meta_path = "/tmp/athena_meta_cmp_#{ctx.box_id}.txt"

    args =
      [
        "--run",
        "--cg",
        "-b",
        "#{ctx.box_id}",
        "-M",
        meta_path,
        "-f",
        "10240",
        "-t",
        "10.0",
        "--cg-mem=262144",
        "-p128",
        "-E",
        "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
        "-r",
        "compile_err.txt",
        "--"
      ] ++ String.split(ctx.lang_config.compile_cmd)

    {_output, exit_code} = System.cmd(@isolate_bin, args)
    File.rm(meta_path)

    if exit_code == 0 do
      :ok
    else
      err_output = read_box_file(ctx, "compile_err.txt")
      {:error, {:compilation_error, err_output}}
    end
  end

  @doc false
  @spec init_sandbox(Context.t()) :: {:ok, Context.t()} | {:error, :init_failed}
  defp init_sandbox(ctx) do
    case System.cmd(@isolate_bin, ["--init", "--cg", "-b", "#{ctx.box_id}"]) do
      {path, 0} ->
        work_dir = String.trim(path)
        box_dir = Path.join(work_dir, "box")

        File.chmod!(box_dir, 0o777)

        {:ok, %{ctx | work_dir: work_dir, box_dir: box_dir}}

      {err, _} ->
        Logger.error("Isolate init failed: #{err}")
        {:error, :init_failed}
    end
  end

  @doc false
  @spec execute(Context.t()) :: {:ok, map()}
  defp execute(ctx) do
    meta_path = "/tmp/athena_meta_#{ctx.box_id}.txt"

    args =
      [
        "--run",
        "--cg",
        "-b",
        "#{ctx.box_id}",
        "-M",
        meta_path,
        "-t",
        "#{ctx.time_limit}",
        "-w",
        "#{ctx.time_limit + 1.0}",
        "-x",
        "#{ctx.time_limit + 1.0}",
        "-f",
        "1024",
        "--cg-mem=#{ctx.memory_limit}",
        "-p64",
        "-E",
        "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
        "-E",
        "PYTHONIOENCODING=utf-8",
        "-i",
        "stdin.txt",
        "-o",
        "stdout.txt",
        "-r",
        "stderr.txt",
        "--"
      ] ++ String.split(ctx.lang_config.run_cmd)

    {_output, exit_code} = System.cmd(@isolate_bin, args)

    if exit_code >= 2 do
      File.rm(meta_path)
      {:error, :system_failure}
    else
      meta = parse_meta(meta_path)
      File.rm(meta_path)
      {:ok, meta}
    end
  end

  @doc false
  @spec cleanup_sandbox(Context.t()) :: :ok
  defp cleanup_sandbox(ctx) do
    System.cmd(@isolate_bin, ["--cleanup", "--cg", "-b", "#{ctx.box_id}"])
    :ok
  end

  @doc false
  @spec parse_meta(String.t()) :: map()
  defp parse_meta(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Map.new(&parse_meta_line/1)

      {:error, _reason} ->
        Logger.warning("Metadata file not found at #{path}")
        %{}
    end
  end

  @doc false
  @spec parse_meta_line(String.t()) :: {String.t(), String.t()}
  defp parse_meta_line(line) do
    case String.split(line, ":", parts: 2) do
      [key, val] -> {key, String.trim(val)}
      [key] -> {key, ""}
    end
  end

  @doc false
  @spec read_box_file(Context.t(), String.t()) :: String.t()
  defp read_box_file(ctx, filename) do
    path = Path.join(ctx.box_dir, filename)
    if File.exists?(path), do: File.read!(path) |> String.trim(), else: ""
  end
end
