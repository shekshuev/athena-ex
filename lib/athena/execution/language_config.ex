defmodule Athena.Execution.LanguageConfig do
  @moduledoc """
  Provides configuration for supported programming languages.
  Defines execution commands and source file names.
  """

  defstruct [:id, :name, :source_file, :compile_cmd, :run_cmd]

  @type t :: %__MODULE__{
          id: integer(),
          name: String.t(),
          source_file: String.t(),
          compile_cmd: String.t() | nil,
          run_cmd: String.t()
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
      run_cmd: "/usr/bin/python3 script.py"
    }
  end

  def get("cpp") do
    %__MODULE__{
      id: 54,
      name: "C++ (GCC 9.2.0)",
      source_file: "main.cpp",
      compile_cmd: "/usr/bin/g++ -O3 main.cpp -o out",
      run_cmd: "./out"
    }
  end

  def get(_), do: nil
end
