defmodule Athena.Gamification do
  @moduledoc """
  Public API for the Gamification context.

  Reacts to learning-activity facts broadcast by `Athena.Learning` (see
  `Athena.Gamification.ActivityListener`) rather than being called directly
  by other contexts. The only inbound calls other contexts make are simple
  reads, e.g. for displaying XP on the account profile page.

  Bounded-context rule followed throughout: any reference to another
  context's data (`Identity.Account`, `Learning.Cohort`, `Content.Block`) is
  a bare `:binary_id` field with no `belongs_to`/`references()` — a soft
  link, not a real FK. The one real FK in this context
  (`BadgeAward.badge_id → Badge`) stays inside Gamification itself.
  """

  alias Athena.Gamification.{XpLedger, AccountStats, Badges, Facts, Leagues, Sprints}
  alias Athena.Repo

  defdelegate total_xp(account_id), to: XpLedger
  defdelegate known_facts(), to: Facts

  defdelegate current_week_standings(cohort_id), to: Leagues
  defdelegate visible_standings(cohort_id, viewer_account_id), to: Leagues
  defdelegate quiet_members(cohort_id), to: Leagues

  defdelegate list_sprints_for_cohort(cohort_id), to: Sprints
  defdelegate get_sprint(id), to: Sprints
  defdelegate create_sprint(user, attrs), to: Sprints
  defdelegate update_sprint(user, sprint, attrs), to: Sprints
  defdelegate delete_sprint(user, sprint), to: Sprints

  defdelegate list_badges(), to: Badges
  defdelegate get_badge(id), to: Badges
  defdelegate create_badge(user, attrs), to: Badges
  defdelegate update_badge(user, badge, attrs), to: Badges
  defdelegate delete_badge(user, badge), to: Badges
  defdelegate test_rule(rule, account_id), to: Badges
  defdelegate list_awards(account_id), to: Badges

  @doc """
  Returns the account's current and longest weekly streak (both 0 if it has
  no gamification activity yet).
  """
  @spec streak(String.t()) :: %{
          current_weeks: non_neg_integer(),
          longest_weeks: non_neg_integer()
        }
  def streak(account_id) do
    case Repo.get_by(AccountStats, account_id: account_id) do
      nil ->
        %{current_weeks: 0, longest_weeks: 0}

      stats ->
        %{current_weeks: stats.current_streak_weeks, longest_weeks: stats.longest_streak_weeks}
    end
  end

  @level_thresholds [0, 100, 250, 500, 1000, 2000, 4000, 8000, 16_000, 32_000]

  @doc """
  Returns the level ladder position for a given XP total: current level
  (1-based), the XP floor of that level, and the XP ceiling of the next one
  (`nil` at the top of the ladder). Computed on the fly — not stored.
  """
  @spec level_for_xp(non_neg_integer()) :: %{
          level: pos_integer(),
          floor: non_neg_integer(),
          ceiling: non_neg_integer() | nil
        }
  def level_for_xp(xp) do
    index = @level_thresholds |> Enum.filter(&(&1 <= xp)) |> length()

    %{
      level: index,
      floor: Enum.at(@level_thresholds, index - 1),
      ceiling: Enum.at(@level_thresholds, index)
    }
  end
end
