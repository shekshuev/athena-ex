defmodule Athena.Audit do
  @moduledoc """
  The audit trail: one `:info` line per domain event that happened, so an
  incident can be reconstructed from production logs.

  This is deliberately *not* request tracing. The step-by-step callback and
  SQL logs (`AthenaWeb.Hooks.Trace`, Ecto) are `:debug` and off in
  production; what stays on is the record of things that actually changed -
  a course was created, a student answered, a submission was graded.

  ## Format

      [event] submission.graded submission_id=1f3c… block_id=8ab2… account_id=55de… status=passed score=8

  Logfmt-ish on purpose: `grep "\\[event\\]"` gives the whole trail,
  `grep "submission.graded"` one kind of event, and the `key=value` pairs
  parse without a decoder. Event names are `<subject>.<past tense verb>`.

  ## Correlating events

  Every line carries whatever `Logger` metadata the current process holds, so
  an event logged while serving a request picks up `trace=` (the LiveView's
  socket id, the same `phx-…` the browser sends) and `user=` for free - see
  `AthenaWeb.Hooks.Trace`. Following one person's actions is
  `grep trace=phx-GOB1D55ZbsQJ8XJh`.

  Work that continues in another process does not inherit that metadata, so
  such a process sets its own correlation id with `put_trace/1`, and the
  events on both sides carry the id of the record they are about
  (`submission_id=`, `course_id=`) - which is what joins the two halves of,
  say, "answer submitted" in the request and "submission graded" in the
  runner.

  ## What belongs here

  State changes a human would ask about after the fact, plus refused attempts
  (`warning/2`) and failures (`error/2`). Not reads, and not anything
  per-keystroke: `Athena.Engagement` events and XP ledger rows are far too
  frequent to narrate and are queryable in their own tables anyway.
  """

  require Logger

  @typedoc "Event fields: ids, statuses, counts. Never whole records."
  @type fields :: keyword() | map()

  @doc """
  Records that something happened, at `:info`.

      Athena.Audit.event("course.created", course_id: course.id, title: course.title)
  """
  @spec event(String.t(), fields()) :: :ok
  def event(name, fields \\ []) when is_binary(name) do
    Logger.info(fn -> line(name, fields) end)
  end

  @doc """
  Logs `name` when `result` is `{:ok, record}`, and passes `result` through
  either way - so an event can be appended to an existing pipeline instead of
  restructuring it:

      course
      |> Course.changeset(attrs)
      |> Repo.update()
      |> Audit.on_ok("course.updated", &[course_id: &1.id, by: user.id])

  The fields are built by a function so nothing is computed when the
  operation failed.
  """
  @spec on_ok(result, String.t(), (term() -> fields())) :: result when result: term()
  def on_ok(result, name, fields_fun)

  def on_ok({:ok, record} = result, name, fields_fun) do
    event(name, fields_fun.(record))
    result
  end

  def on_ok(result, _name, _fields_fun), do: result

  @doc """
  Records a refused or rejected attempt, at `:warning`.

  For things that are not bugs but are worth seeing without turning the level
  up: a permission denial, a submission rejected because the deadline passed.

      Athena.Audit.warning("submission.rejected", block_id: id, reason: :locked)
  """
  @spec warning(String.t(), fields()) :: :ok
  def warning(name, fields \\ []) when is_binary(name) do
    Logger.warning(fn -> line(name, fields) end)
  end

  @doc """
  Records a failure, at `:error`.

      Athena.Audit.error("grading.failed", submission_id: id, reason: :timeout)
  """
  @spec error(String.t(), fields()) :: :ok
  def error(name, fields \\ []) when is_binary(name) do
    Logger.error(fn -> line(name, fields) end)
  end

  @doc """
  Sets the correlation id for the current process.

  For work that runs outside a request - an Oban job, a grading task, a
  GenServer - whose process holds none of the request's `Logger` metadata.
  The id is prefixed so its origin is obvious in a log (`trace=job-1234`).

      Athena.Audit.put_trace("job-\#{job.id}")
  """
  @spec put_trace(String.t()) :: :ok
  def put_trace(id) when is_binary(id), do: Logger.metadata(trace: id)

  defp line(name, fields) do
    ["[event] ", name, Enum.map(fields, &pair/1)]
  end

  defp pair({_key, nil}), do: []
  defp pair({key, value}), do: [" ", to_string(key), "=", value(value)]

  # Structs arrive by accident (passing the record instead of its id); log
  # what identifies them rather than dumping the whole thing into the log.
  defp value(%_struct{id: id}), do: value(id)
  defp value(%struct{}), do: inspect(struct)
  defp value(value) when is_binary(value), do: quote_if_spaced(value)
  defp value(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp value(%Date{} = value), do: Date.to_iso8601(value)
  defp value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp value(value) when is_list(value), do: "#{length(value)}"
  defp value(value), do: inspect(value, limit: 5, printable_limit: 120)

  # A free-text field (a title) would otherwise break `key=value` parsing.
  defp quote_if_spaced(value) do
    trimmed = String.slice(value, 0, 120)

    if String.contains?(trimmed, [" ", "="]), do: inspect(trimmed), else: trimmed
  end
end
