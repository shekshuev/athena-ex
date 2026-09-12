defmodule Athena.Gamification.XpLedger do
  @moduledoc """
  Awards XP for learning activity and maintains the cached
  `Athena.Gamification.AccountStats.total_xp`.

  `record_activity/1` is the single entry point, driven by the
  `{:block_completed, payload}` fact `Athena.Learning` broadcasts on the
  `"learning_events"` PubSub topic (via `Athena.Gamification.ActivityListener`)
  — Gamification never calls into Learning directly.
  """
  alias Athena.Repo
  alias Athena.Gamification.{XpEvent, XpRule, AccountStats, Sprints}

  @doc """
  Records a `:block_completed` fact and awards flat XP for the block's type,
  if that type has a non-zero base amount configured.

  Idempotent: re-processing the same `(account_id, block_id)` pair (e.g. a
  duplicate PubSub delivery) is a no-op, enforced by a partial unique index
  rather than an application-level check, so it's race-safe under concurrent
  processing.
  """
  @spec record_activity(map()) :: {:ok, :awarded | :skipped}
  def record_activity(%{account_id: account_id, block_id: block_id} = payload) do
    case base_amount_for(Map.get(payload, :block_type)) do
      amount when amount > 0 ->
        final_amount = apply_sprint_multiplier(account_id, amount)

        insert_event(
          account_id,
          Map.get(payload, :cohort_id),
          :block_progress,
          block_id,
          final_amount
        )

      _ ->
        {:ok, :skipped}
    end
  end

  @doc """
  Awards the flat XP bonus for solving the day's challenge — same base
  amount as the block's type normally earns. `source_id` is the
  `DailyChallenge` row's id, not the block id, so the ledger's
  `(account_id, source_type, source_id)` dedup index allows one award per
  day even though the same block can be re-served on a later day.
  """
  @spec record_daily_challenge(map()) :: {:ok, :awarded | :skipped}
  def record_daily_challenge(%{
        account_id: account_id,
        daily_challenge_id: daily_challenge_id,
        block_type: block_type
      }) do
    case base_amount_for(block_type) do
      amount when amount > 0 ->
        insert_event(account_id, nil, :daily_challenge, daily_challenge_id, amount)

      _ ->
        {:ok, :skipped}
    end
  end

  defp apply_sprint_multiplier(account_id, amount) do
    case Sprints.active_multiplier_for_account(account_id) do
      nil ->
        amount

      multiplier ->
        multiplier |> Decimal.mult(amount) |> Decimal.round(0) |> Decimal.to_integer()
    end
  end

  @doc """
  Returns an account's cached total XP (0 if it has none yet).
  """
  @spec total_xp(String.t()) :: non_neg_integer()
  def total_xp(account_id) do
    case Repo.get_by(AccountStats, account_id: account_id) do
      nil -> 0
      stats -> stats.total_xp
    end
  end

  defp base_amount_for(nil), do: 0

  defp base_amount_for(block_type) do
    case Repo.get_by(XpRule, block_type: block_type) do
      nil -> 0
      rule -> rule.base_amount
    end
  end

  defp insert_event(account_id, cohort_id, source_type, source_id, amount) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      id: Ecto.UUID.generate(),
      account_id: account_id,
      cohort_id: cohort_id,
      source_type: source_type,
      source_id: source_id,
      amount: amount,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(XpEvent, [attrs],
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment,
              "(account_id, source_type, source_id) WHERE source_id IS NOT NULL"}
         ) do
      {1, _} ->
        bump_total_xp(account_id, amount)
        {:ok, :awarded}

      {0, _} ->
        {:ok, :skipped}
    end
  end

  defp bump_total_xp(account_id, amount) do
    %AccountStats{}
    |> AccountStats.changeset(%{account_id: account_id, total_xp: amount})
    |> Repo.insert(
      on_conflict: [inc: [total_xp: amount]],
      conflict_target: :account_id
    )
  end
end
