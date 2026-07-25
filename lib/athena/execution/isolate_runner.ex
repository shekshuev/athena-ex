defmodule Athena.Execution.IsolateRunner do
  @moduledoc """
  Low-level wrapper around the `isolate` binary.
  Handles sandbox lifecycle: init -> setup -> run -> cleanup.
  Uses cgroups (--cg) for strict and accurate resource limiting.
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
    System.cmd(@isolate_bin, ["--cleanup", "--cg", "-b", "#{ctx.box_id}"], stderr_to_stdout: true)

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
    System.cmd(@isolate_bin, ["--cleanup", "--cg", "-b", "#{ctx.box_id}"], stderr_to_stdout: true)

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
    formatted_input = format_stdin_content(input)

    case File.write(stdin_path, formatted_input) do
      :ok -> :ok
      {:error, _} -> {:error, :write_failed}
    end
  end

  defp format_stdin_content(nil), do: "\n"
  defp format_stdin_content(""), do: "\n"

  defp format_stdin_content(input) when is_binary(input) do
    if String.ends_with?(input, "\n"), do: input, else: input <> "\n"
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
        "-w",
        "12.0",
        "-m",
        "262144",
        "-p128",
        "-E",
        "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
        "-r",
        "compile_err.txt",
        "--"
      ] ++ String.split(ctx.lang_config.compile_cmd)

    {_output, exit_code} = System.cmd(@isolate_bin, args, stderr_to_stdout: true)
    File.rm(meta_path)

    if exit_code == 0 do
      Logger.debug("[IsolateRunner] Box #{ctx.box_id} [#{ctx.lang_config.name}] compiled successfully.")
      :ok
    else
      err_output = read_box_file(ctx, "compile_err.txt")
      Logger.warning("[IsolateRunner] Box #{ctx.box_id} [#{ctx.lang_config.name}] compilation failed:\n#{err_output}")
      {:error, {:compilation_error, err_output}}
    end
  end

  @doc false
  @spec init_sandbox(Context.t(), integer()) :: {:ok, Context.t()} | {:error, :init_failed}
  defp init_sandbox(ctx, retries \\ 5) do
    System.cmd(@isolate_bin, ["--cleanup", "--cg", "-b", "#{ctx.box_id}"], stderr_to_stdout: true)

    case System.cmd(@isolate_bin, ["--init", "--cg", "-b", "#{ctx.box_id}"], stderr_to_stdout: true) do
      {path, 0} ->
        work_dir = String.trim(path)
        box_dir = Path.join(work_dir, "box")

        File.chmod!(box_dir, 0o777)

        {:ok, %{ctx | work_dir: work_dir, box_dir: box_dir}}

      {err, _} ->
        if retries > 0 do
          Process.sleep(150)
          init_sandbox(ctx, retries - 1)
        else
          Logger.error("Isolate init failed for box #{ctx.box_id}: #{err}")
          {:error, :init_failed}
        end
    end
  end

  @doc false
  @spec execute(Context.t()) :: {:ok, map()} | {:error, :system_failure}
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
        "-m",
        "#{ctx.memory_limit}",
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

    {_output, exit_code} = System.cmd(@isolate_bin, args, stderr_to_stdout: true)

    if exit_code >= 2 do
      File.rm(meta_path)
      Logger.error("[IsolateRunner] Box #{ctx.box_id} fatal isolate error (exit_code=#{exit_code})")
      {:error, :system_failure}
    else
      meta = parse_meta(meta_path)
      File.rm(meta_path)

      status = meta["status"] || "OK"
      time = meta["time"] || "0.0"
      exitcode = meta["exitcode"] || "0"

      Logger.info("[IsolateRunner] Box #{ctx.box_id} [#{ctx.lang_config.name}] -> status=#{status}, exitcode=#{exitcode}, time=#{time}s")
      {:ok, meta}
    end
  end

  @doc false
  @spec cleanup_sandbox(Context.t()) :: :ok
  defp cleanup_sandbox(ctx) do
    case System.cmd(@isolate_bin, ["--cleanup", "--cg", "-b", "#{ctx.box_id}"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        Process.sleep(100)
        System.cmd(@isolate_bin, ["--cleanup", "--cg", "-b", "#{ctx.box_id}"], stderr_to_stdout: true)
        :ok
    end
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
