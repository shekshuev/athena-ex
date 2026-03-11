defmodule Athena.Identity.ACL do
  @moduledoc """
  Access Control List (ACL) engine.
  Handles object-level policy checks and dynamically modifies Ecto queries.
  """

  import Ecto.Query

  @spec check(String.t(), String.t(), map()) :: boolean()
  def check("own_only", user_id, %{owner_id: owner_id}), do: user_id == owner_id
  def check("not_published", _user_id, %{is_published: false}), do: true
  def check("only_published", _user_id, %{is_published: true}), do: true

  def check("published_or_owner", user_id, resource) do
    check("only_published", user_id, resource) or check("own_only", user_id, resource)
  end

  def check(_, _, _), do: false

  @doc """
  Applies a list of policies to an Ecto Query.
  It naturally connects multiple policies with AND logic.
  """
  @spec apply_policies(Ecto.Query.t(), String.t(), [String.t()]) :: Ecto.Query.t()
  def apply_policies(query, _user_id, []), do: query

  def apply_policies(query, user_id, policies) do
    Enum.reduce(policies, query, fn policy, current_query ->
      apply_policy(current_query, policy, user_id)
    end)
  end

  defp apply_policy(query, "own_only", user_id) do
    where(query, [q], q.owner_id == ^user_id)
  end

  defp apply_policy(query, "not_published", _user_id) do
    where(query, [q], q.is_published == false)
  end

  defp apply_policy(query, "only_published", _user_id) do
    where(query, [q], q.is_published == true)
  end

  defp apply_policy(query, "published_or_owner", user_id) do
    where(query, [q], q.is_published == true or q.owner_id == ^user_id)
  end
end
