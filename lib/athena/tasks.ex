defmodule Athena.Tasks do
  @moduledoc """
  Contract for manual maintenance tasks, each in its own `Athena.Tasks` module.

  Implementations expose `run/1` with task-specific keyword options and may
  provide `run/0` through a default argument. For example:

      Athena.Tasks.BackfillSearchText.run()

  Tasks document whether success means work was completed or only scheduled.
  """

  @callback run(keyword()) :: {:ok, term()} | {:error, term()}
end
