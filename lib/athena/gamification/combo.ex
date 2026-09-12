defmodule Athena.Gamification.Combo do
  @moduledoc """
  Tracks each account's current "no mistakes in a row" streak of graded
  submissions — fed by `Athena.Learning`'s existing `"grading:updates"`
  PubSub broadcasts (see `Athena.Gamification.ActivityListener`), the same
  fire-and-forget channel already used to push live updates to the grading
  dashboard. No new coupling to Learning was needed for this.

  Scoped to top-level submissions only (`parent_submission_id == nil`) —
  per-question exam submissions are internal detail, not a standalone
  "attempt" a student would recognize as one link in a combo.
  """
  alias Athena.Repo
  alias Athena.Gamification.AccountStats

  @success_statuses ~w(accepted)a
  @terminal_statuses ~w(accepted graded wrong_answer rejected time_limit_exceeded
                         memory_limit_exceeded runtime_error compilation_error system_error)a

  @doc """
  Updates `current_combo` from a submission's terminal result: +1 on
  success, reset to 0 on failure. A no-op for child (per-question exam)
  submissions and non-terminal statuses (`pending`, `processing`,
  `needs_review`, `draft`).
  """
  @spec record_result(map()) :: :ok
  def record_result(%{parent_submission_id: nil, status: status} = submission)
      when status in @terminal_statuses do
    if success?(submission) do
      bump_combo(submission.account_id)
    else
      reset_combo(submission.account_id)
    end

    :ok
  end

  def record_result(_submission), do: :ok

  defp success?(%{status: status}) when status in @success_statuses, do: true
  defp success?(%{status: :graded, score: 100}), do: true
  defp success?(_submission), do: false

  defp bump_combo(account_id) do
    %AccountStats{}
    |> AccountStats.changeset(%{account_id: account_id, current_combo: 1})
    |> Repo.insert(on_conflict: [inc: [current_combo: 1]], conflict_target: :account_id)
  end

  defp reset_combo(account_id) do
    %AccountStats{}
    |> AccountStats.changeset(%{account_id: account_id, current_combo: 0})
    |> Repo.insert(
      on_conflict: {:replace, [:current_combo, :updated_at]},
      conflict_target: :account_id
    )
  end
end
