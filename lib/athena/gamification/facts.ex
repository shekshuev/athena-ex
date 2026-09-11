defmodule Athena.Gamification.Facts do
  @moduledoc """
  Computes individual measurable "facts" about an account on demand, for the
  badge rule-DSL (`Athena.Gamification.RuleEngine`). Extending the catalog
  with a new measurable fact means adding one clause here — no schema or
  migration changes, and existing badges' saved `rule` trees keep working
  unchanged.

  Deliberately starts smaller than a wishlist: only facts backed by data
  that actually exists today (XP, streak, combo, submissions). League and
  sprint participation counts are natural additions once those land.
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Gamification.{AccountStats, XpEvent, LeagueResult}
  alias Athena.Learning.Submission
  alias Athena.Content.Block

  @known_facts ~w(
    total_xp weekly_xp streak_weeks current_combo
    accepted_submissions_count first_try_accept_count league_top_count
  )

  @doc "The fixed set of fact names a badge rule may reference."
  @spec known_facts() :: [String.t()]
  def known_facts, do: @known_facts

  @doc """
  Returns the numeric value of `fact_name` (with optional string-keyed
  `args`) for an account. An unknown fact name returns `0` rather than
  raising, so a badge referencing a retired/misspelled fact simply never
  triggers instead of crashing the evaluator for every account.
  """
  @spec value(String.t(), map(), String.t()) :: number()
  def value(fact_name, args \\ %{}, account_id)

  def value("total_xp", _args, account_id), do: stats(account_id).total_xp
  def value("streak_weeks", _args, account_id), do: stats(account_id).current_streak_weeks
  def value("current_combo", _args, account_id), do: stats(account_id).current_combo
  def value("weekly_xp", _args, account_id), do: weekly_xp(account_id)

  def value("accepted_submissions_count", args, account_id),
    do: accepted_submissions_count(account_id, Map.get(args, "block_type"))

  def value("first_try_accept_count", _args, account_id),
    do: first_try_accept_count(account_id)

  def value("league_top_count", _args, account_id), do: league_top_count(account_id)

  def value(_unknown_fact, _args, _account_id), do: 0

  defp stats(account_id) do
    Repo.get_by(AccountStats, account_id: account_id) ||
      %AccountStats{total_xp: 0, current_streak_weeks: 0, current_combo: 0}
  end

  defp weekly_xp(account_id) do
    week_start = Date.beginning_of_week(Date.utc_today())
    week_start_dt = DateTime.new!(week_start, ~T[00:00:00], "Etc/UTC")

    XpEvent
    |> where([e], e.account_id == ^account_id and e.inserted_at >= ^week_start_dt)
    |> Repo.aggregate(:sum, :amount)
    |> case do
      nil -> 0
      sum -> sum
    end
  end

  defp accepted_submissions_count(account_id, nil) do
    Submission
    |> where(
      [s],
      s.account_id == ^account_id and is_nil(s.parent_submission_id) and s.status == :accepted
    )
    |> Repo.aggregate(:count)
  end

  defp accepted_submissions_count(account_id, block_type) do
    Submission
    |> join(:inner, [s], b in Block, on: b.id == s.block_id)
    |> where(
      [s, b],
      s.account_id == ^account_id and is_nil(s.parent_submission_id) and
        s.status == :accepted and b.type == ^block_type
    )
    |> Repo.aggregate(:count)
  end

  defp league_top_count(account_id) do
    LeagueResult
    |> where([r], r.account_id == ^account_id and r.tier == :top)
    |> Repo.aggregate(:count)
  end

  defp first_try_accept_count(account_id) do
    first_attempts =
      from s in Submission,
        where:
          s.account_id == ^account_id and is_nil(s.parent_submission_id) and
            s.status != :draft,
        distinct: [asc: s.block_id],
        order_by: [asc: s.block_id, asc: s.inserted_at],
        select: %{status: s.status}

    from(r in subquery(first_attempts), where: r.status == :accepted)
    |> Repo.aggregate(:count)
  end
end
