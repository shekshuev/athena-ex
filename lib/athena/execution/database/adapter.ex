defmodule Athena.Execution.Database.Adapter do
  @moduledoc "Contract for SQL sandbox engines. Adapters own credentials, restrictions, cancellation and cleanup."

  @callback execute_in_sandbox(integer(), String.t() | nil, (pid() -> term())) ::
              {:ok, term()} | {:error, term()}
  @callback query(pid(), String.t(), number()) :: {:ok, map()} | {:error, term()}
end
