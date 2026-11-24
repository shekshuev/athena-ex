defmodule Athena.Execution.Database.Result do
  @moduledoc "Driver-independent SQL result; raw values are preserved for comparison."
  defstruct columns: nil, rows: nil, num_rows: 0
end
