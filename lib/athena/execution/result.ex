defmodule Athena.Execution.TestResult do
  @moduledoc "Represents the result of a single test case execution."

  defstruct [
    :status,
    :score,
    :max_score,
    :time,
    :memory,
    :stdout,
    :stderr,
    :input,
    :expected,
    :is_hidden
  ]

  @type t :: %__MODULE__{
          status: atom(),
          score: integer(),
          max_score: integer(),
          time: float(),
          memory: integer(),
          stdout: String.t(),
          stderr: String.t() | nil,
          input: String.t(),
          expected: String.t(),
          is_hidden: boolean()
        }
end

defmodule Athena.Execution.Result do
  @moduledoc "Represents the final aggregated result of a verification run."

  alias Athena.Execution.TestResult

  defstruct [:status, :score, :time, :memory, :test_results]

  @type t :: %__MODULE__{
          status: atom(),
          score: integer(),
          time: float(),
          memory: integer(),
          test_results: [TestResult.t()]
        }
end
