defmodule Athena.Gamification.Leagues do
  @moduledoc """
  Weekly league standings scoped to a single academic cohort (20-40
  people), not a school-wide leaderboard — ranked by weekly XP (practice),
  not final grades, and reset every week so one bad week doesn't compound
  into a lasting label.

  Design choices that keep this from becoming a source of shame for
  whoever's at the bottom:
  - Only a `:top` tier (roughly the top 30%) is called out; there is no
    "bottom" tier shown to peers, only `:active` (ranked, visible) and
    `:quiet` (no XP this week — hidden from other members entirely, see
    `visible_standings/2`, and surfaced only to instructors as a support
    signal, not a public rank).
  - The default view is a "sandwich" (top 3 + your own ±2), not the full
    roster — see `sandwich_view/2`.
  - An account can opt out of being shown to others at all via
    `Athena.Identity.Profile.metadata["show_in_league"] == false`; it still
    sees its own row.
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Gamification.{Facts, LeagueResult, XpEvent}
  alias Athena.Learning.CohortMembership
  alias Athena.Identity.{Account, Profile}

  @top_tier_fraction 0.3

  @doc """
  Computes the *current, still-open* week's standings for a cohort's
  members, ranked richest-first. Nothing is persisted — only closed weeks
  get snapshotted (`snapshot_week/1`, via the weekly rollup job).
  """
  @spec current_week_standings(String.t()) :: [map()]
  def current_week_standings(cohort_id) do
    cohort_id
    |> member_ids()
    |> Enum.map(fn account_id ->
      %{account_id: account_id, weekly_xp: Facts.value("weekly_xp", %{}, account_id)}
    end)
    |> rank_and_tier()
  end

  @doc """
  Filters and shapes standings for display to `viewer_account_id`: drops
  `:quiet` members and members who opted out (`show_in_league: false`) —
  except the viewer's own row, which is always included — then returns the
  default "sandwich" view (top 3 plus the viewer's own rank ±2).
  """
  @spec visible_standings(String.t(), String.t()) :: [map()]
  def visible_standings(cohort_id, viewer_account_id) do
    standings = current_week_standings(cohort_id)
    opted_out_ids = opted_out_account_ids(Enum.map(standings, & &1.account_id))

    standings
    |> Enum.filter(fn entry ->
      entry.account_id == viewer_account_id or
        (entry.tier != :quiet and entry.account_id not in opted_out_ids)
    end)
    |> sandwich_view(viewer_account_id)
  end

  @doc """
  Returns the default "sandwich" view for a standings list — top 3 plus the
  viewer's own rank ±2 — instead of the full ranked list. Deduplicated and
  re-sorted by rank. If the viewer isn't present in `standings`, just the
  top 3 is returned.
  """
  @spec sandwich_view([map()], String.t()) :: [map()]
  def sandwich_view(standings, account_id) do
    top3 = Enum.take(standings, 3)

    around =
      case Enum.find(standings, &(&1.account_id == account_id)) do
        nil -> []
        %{rank: rank} -> Enum.filter(standings, &(&1.rank >= rank - 2 and &1.rank <= rank + 2))
      end

    (top3 ++ around)
    |> Enum.uniq_by(& &1.account_id)
    |> Enum.sort_by(& &1.rank)
  end

  @doc """
  Lists members with no XP this week (`:quiet` tier) — not shown to peers,
  but useful to an instructor as an outreach signal.
  """
  @spec quiet_members(String.t()) :: [map()]
  def quiet_members(cohort_id) do
    cohort_id |> current_week_standings() |> Enum.filter(&(&1.tier == :quiet))
  end

  @doc """
  Snapshots `week_start`'s (a closed week) standings for every academic
  cohort into `LeagueResult`. Called by the weekly rollup job.
  """
  @spec snapshot_week(Date.t()) :: :ok
  def snapshot_week(week_start) do
    Athena.Learning.Cohort
    |> where([c], c.type == :academic)
    |> select([c], c.id)
    |> Repo.all()
    |> Enum.each(&snapshot_cohort_week(&1, week_start))

    :ok
  end

  defp snapshot_cohort_week(cohort_id, week_start) do
    cohort_id
    |> member_ids()
    |> Enum.map(fn account_id ->
      %{account_id: account_id, weekly_xp: weekly_xp_for(account_id, week_start)}
    end)
    |> rank_and_tier()
    |> Enum.each(&upsert_result(cohort_id, week_start, &1))
  end

  defp upsert_result(cohort_id, week_start, entry) do
    %LeagueResult{}
    |> LeagueResult.changeset(%{
      cohort_id: cohort_id,
      week_start: week_start,
      account_id: entry.account_id,
      weekly_xp: entry.weekly_xp,
      rank: entry.rank,
      tier: entry.tier
    })
    |> Repo.insert(
      on_conflict: {:replace, [:weekly_xp, :rank, :tier, :updated_at]},
      conflict_target: [:cohort_id, :week_start, :account_id]
    )
  end

  defp member_ids(cohort_id) do
    CohortMembership
    |> where([m], m.cohort_id == ^cohort_id)
    |> select([m], m.account_id)
    |> Repo.all()
  end

  defp weekly_xp_for(account_id, week_start) do
    week_start_dt = Athena.TimeZones.start_of_day(week_start)
    week_end_dt = Athena.TimeZones.start_of_day(Date.add(week_start, 7))

    XpEvent
    |> where([e], e.account_id == ^account_id)
    |> where([e], e.inserted_at >= ^week_start_dt and e.inserted_at < ^week_end_dt)
    |> Repo.aggregate(:sum, :amount)
    |> case do
      nil -> 0
      sum -> sum
    end
  end

  defp rank_and_tier(entries) do
    sorted = Enum.sort_by(entries, & &1.weekly_xp, :desc)
    total = length(sorted)
    top_cutoff = max(1, ceil(total * @top_tier_fraction))

    sorted
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, rank} ->
      Map.merge(entry, %{rank: rank, tier: tier_for(entry.weekly_xp, rank, top_cutoff)})
    end)
  end

  defp tier_for(0, _rank, _cutoff), do: :quiet
  defp tier_for(_xp, rank, cutoff) when rank <= cutoff, do: :top
  defp tier_for(_xp, _rank, _cutoff), do: :active

  defp opted_out_account_ids([]), do: MapSet.new()

  defp opted_out_account_ids(account_ids) do
    Account
    |> where([a], a.id in ^account_ids)
    |> join(:inner, [a], p in Profile, on: p.owner_id == a.id)
    |> where([a, p], fragment("?->>'show_in_league' = 'false'", p.metadata))
    |> select([a], a.id)
    |> Repo.all()
    |> MapSet.new()
  end
end
