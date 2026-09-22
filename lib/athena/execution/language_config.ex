defmodule Athena.Execution.LanguageConfig do
  @moduledoc """
  Provides configuration for supported programming languages.
  Defines execution commands and source file names.
  """

  defstruct [:id, :name, :source_file, :compile_cmd, :run_cmd, :family]

  @type family :: :db | :compiled | :script

  @type t :: %__MODULE__{
          id: integer(),
          name: String.t(),
          source_file: String.t(),
          compile_cmd: String.t() | nil,
          run_cmd: String.t(),
          family: family()
        }

  @doc """
  Retrieves the configuration for a specific language identifier.
  Returns `nil` if the language is not supported.
  """
  @spec get(String.t()) :: t() | nil
  def get("python3") do
    %__MODULE__{
      id: 71,
      name: "Python (3.8.1)",
      source_file: "script.py",
      run_cmd: "/usr/bin/python3 script.py",
      family: :script
    }
  end

  def get("cpp") do
    %__MODULE__{
      id: 54,
      name: "C++ (GCC 9.2.0)",
      source_file: "main.cpp",
      compile_cmd: "/usr/bin/g++ -O3 main.cpp -o out",
      run_cmd: "./out",
      family: :compiled
    }
  end

  def get("sql") do
    %__MODULE__{
      id: 82,
      name: "PostgreSQL (16)",
      source_file: "query.sql",
      run_cmd: "",
      family: :db
    }
  end

  def get(_), do: nil

  @doc """
  Returns language list for UI selects.
  """
  def options do
    [
      {"Python", "python3"},
      {"C++", "cpp"},
      {"SQL (PostgreSQL 16)", "sql"}
    ]
  end

  @doc """
  Returns the default language identifier.
  """
  def default_language, do: "python3"

  # {backend language identifier, CodeMirror mode, display label}
  @cm_languages [
    {"python3", "python", "Python"},
    {"cpp", "cpp", "C++"},
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

  @doc """
  Returns `{cm_mode, label}` pairs for every supported CodeMirror language,
  for UI pickers such as the Tiptap code-block language switcher.
  """
  @spec cm_languages() :: [{String.t(), String.t()}]
  def cm_languages, do: Enum.map(@cm_languages, fn {_id, cm_mode, label} -> {cm_mode, label} end)
end
