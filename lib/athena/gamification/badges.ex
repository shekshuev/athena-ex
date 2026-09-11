defmodule Athena.Gamification.Badges do
  @moduledoc """
  Admin-facing badge catalog CRUD, plus the evaluator that awards badges to
  an account based on its current facts.
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Gamification.{Badge, BadgeAward, RuleEngine}

  @spec list_badges() :: [Badge.t()]
  def list_badges do
    Badge |> order_by([b], asc: b.title) |> Repo.all()
  end

  @spec get_badge(String.t()) :: {:ok, Badge.t()} | {:error, :not_found}
  def get_badge(id) do
    case Repo.get(Badge, id) do
      nil -> {:error, :not_found}
      badge -> {:ok, badge}
    end
  end

  @spec create_badge(map()) :: {:ok, Badge.t()} | {:error, Ecto.Changeset.t()}
  def create_badge(attrs) do
    %Badge{}
    |> Badge.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_badge(Badge.t(), map()) :: {:ok, Badge.t()} | {:error, Ecto.Changeset.t()}
  def update_badge(%Badge{} = badge, attrs) do
    badge
    |> Badge.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_badge(Badge.t()) :: {:ok, Badge.t()} | {:error, Ecto.Changeset.t()}
  def delete_badge(%Badge{} = badge), do: Repo.delete(badge)

  @doc """
  Tests a badge's rule against one account without awarding it — the admin
  "test on a student" preview before activating a badge.
  """
  @spec test_rule(map(), String.t()) :: boolean()
  def test_rule(rule, account_id), do: RuleEngine.evaluate(rule, account_id)

  @doc """
  Awards every active badge an account newly qualifies for. Idempotent —
  already-awarded badges are skipped (both by an in-memory check and, as a
  last line of defense, the `(account_id, badge_id)` unique index), so
  re-evaluation after every learning event is safe.
  """
  @spec evaluate_for_account(String.t()) :: :ok
  def evaluate_for_account(account_id) do
    already_awarded_ids =
      BadgeAward
      |> where([a], a.account_id == ^account_id)
      |> select([a], a.badge_id)
      |> Repo.all()
      |> MapSet.new()

    Badge
    |> where([b], b.is_active == true)
    |> Repo.all()
    |> Enum.reject(&(&1.id in already_awarded_ids))
    |> Enum.filter(&RuleEngine.evaluate(&1.rule, account_id))
    |> Enum.each(&award(&1, account_id))

    :ok
  end

  defp award(badge, account_id) do
    %BadgeAward{}
    |> BadgeAward.changeset(%{
      account_id: account_id,
      badge_id: badge.id,
      awarded_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:account_id, :badge_id])
  end

  @doc """
  Lists an account's earned badges (most recent first), each preloaded with
  its badge details for display.
  """
  @spec list_awards(String.t()) :: [BadgeAward.t()]
  def list_awards(account_id) do
    BadgeAward
    |> where([a], a.account_id == ^account_id)
    |> order_by([a], desc: a.awarded_at)
    |> preload(:badge)
    |> Repo.all()
  end
end
