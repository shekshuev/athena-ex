defmodule Athena.Gamification.Sprints do
  @moduledoc """
  CRUD for cohort sprints, gated by the same cohort-management check the
  Learning context already uses for schedule overrides — no separate
  gamification permission needed, since "who may run a sprint for this
  cohort" is exactly "who may manage this cohort". Also the active-XP-
  multiplier lookup `Athena.Gamification.XpLedger` consults when awarding
  XP.
  """
  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning
  alias Athena.Gamification.Sprint
  alias Athena.Learning.CohortMembership

  @spec list_sprints_for_cohort(String.t()) :: [Sprint.t()]
  def list_sprints_for_cohort(cohort_id) do
    Sprint
    |> where([s], s.cohort_id == ^cohort_id)
    |> order_by([s], desc: s.starts_at)
    |> Repo.all()
  end

  @spec get_sprint(String.t()) :: {:ok, Sprint.t()} | {:error, :not_found}
  def get_sprint(id) do
    case Repo.get(Sprint, id) do
      nil -> {:error, :not_found}
      sprint -> {:ok, sprint}
    end
  end

  @doc """
  Creates a sprint, requiring `user` to manage the target cohort.
  """
  @spec create_sprint(map(), map()) ::
          {:ok, Sprint.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create_sprint(user, attrs) do
    with {:ok, cohort} <- fetch_cohort(user, Map.get(attrs, "cohort_id")),
         true <- Learning.can_manage_cohort_processes?(user, cohort) do
      %Sprint{}
      |> Sprint.changeset(Map.put(attrs, "created_by", user.id))
      |> Repo.insert()
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc """
  Updates a sprint, requiring `user` to manage its cohort.
  """
  @spec update_sprint(map(), Sprint.t(), map()) ::
          {:ok, Sprint.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_sprint(user, %Sprint{} = sprint, attrs) do
    with {:ok, cohort} <- fetch_cohort(user, sprint.cohort_id),
         true <- Learning.can_manage_cohort_processes?(user, cohort) do
      sprint |> Sprint.changeset(attrs) |> Repo.update()
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc """
  Deletes a sprint, requiring `user` to manage its cohort.
  """
  @spec delete_sprint(map(), Sprint.t()) ::
          {:ok, Sprint.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def delete_sprint(user, %Sprint{} = sprint) do
    with {:ok, cohort} <- fetch_cohort(user, sprint.cohort_id),
         true <- Learning.can_manage_cohort_processes?(user, cohort) do
      Repo.delete(sprint)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp fetch_cohort(_user, nil), do: {:error, :not_found}
  defp fetch_cohort(user, cohort_id), do: Learning.get_cohort(user, cohort_id)

  @doc """
  Returns the highest XP multiplier from any sprint currently running for a
  cohort the account belongs to, or `nil` if none is active right now.
  """
  @spec active_multiplier_for_account(String.t()) :: Decimal.t() | nil
  def active_multiplier_for_account(account_id) do
    now = DateTime.utc_now()

    cohort_ids_query =
      from cm in CohortMembership, where: cm.account_id == ^account_id, select: cm.cohort_id

    Sprint
    |> where([s], s.is_active == true)
    |> where([s], s.cohort_id in subquery(cohort_ids_query))
    |> where([s], s.starts_at <= ^now and s.ends_at >= ^now)
    |> select([s], max(s.xp_multiplier))
    |> Repo.one()
  end
end
