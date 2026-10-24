defmodule Athena.Tracing do
  @moduledoc """
  Request tracing that lives outside the web layer.

  The per-callback tracing is in `AthenaWeb.Hooks.Trace` (LiveView) and
  `AthenaWeb.Plugs.Trace` (HTTP). This module attaches the telemetry-backed
  loggers for the work those requests hand off to, which runs in its own
  processes and so cannot inherit the request's `Logger` metadata:

    * background jobs, through Oban's own telemetry;
    * code execution, which crosses to a runner node.

  Called once from `Athena.Application.start/2`.

  Database queries need nothing here: `Ecto` logs every one at `:debug`
  already, and because it logs from the calling process those lines pick up
  the request's `trace=`/`user=` metadata on their own.
  """

  require Logger

  @doc """
  Attaches every telemetry logger the app wants. Idempotent: re-attaching an
  existing handler id is ignored, so this is safe to call more than once
  (releases that boot several roles in one node, tests).
  """
  @spec attach() :: :ok
  def attach do
    attach_oban_logger()
    :ok
  end

  # Oban's default logger reports job start/stop/exception with the worker,
  # job id, args and duration. Its own level, since a job's lifecycle is
  # worth seeing even when request tracing is off.
  defp attach_oban_logger do
    if Code.ensure_loaded?(Oban.Telemetry) do
      case Oban.Telemetry.attach_default_logger(level: :info) do
        :ok -> :ok
        {:error, :already_exists} -> :ok
      end
    end
  end
end
