defmodule Athena.Identity.Acl do
  @moduledoc """
  Core Access Control List logic.
  Handles boolean permission checks and Ecto query scoping based on user roles and policies.
  """

  import Ecto.Query

  @doc """
  Checks if a user has a specific permission, optionally evaluating object-level policies.
  """
  @spec can?(map() | nil, String.t(), map() | nil) :: boolean()
  def can?(user, permission, resource \\ nil)

  def can?(nil, _permission, _resource), do: false

  def can?(user, permission, resource) do
    cond do
      "admin" in user.role.permissions ->
        true

      permission in user.role.permissions ->
        policies = Map.get(user.role.policies || %{}, permission, [])
        check_policies(policies, user, resource)

      true ->
        false
    end
  end

  @doc """
  Checks if a user has AT LEAST ONE of the provided permissions.
  Useful for rendering navigation groups.
  """
  @spec can_any?(map() | nil, [String.t()]) :: boolean()
  def can_any?(nil, _permissions), do: false

  def can_any?(user, permissions) when is_list(permissions) do
    if "admin" in user.role.permissions do
      true
    else
      Enum.any?(permissions, &(&1 in user.role.permissions))
    end
  end

  defp check_policies([], _user, _resource), do: true

  defp check_policies(_policies, _user, nil), do: true

  defp check_policies(policies, user, resource) do
    Enum.all?(policies, &check_policy(&1, user, resource))
  end

  defp check_policy("own_only", user, resource), do: resource.owner_id == user.id
  defp check_policy("not_published", _user, resource), do: resource.is_published == false
  defp check_policy("only_published", _user, resource), do: resource.is_published == true

  defp check_policy("published_or_owner", user, resource) do
    resource.is_published == true or resource.owner_id == user.id
  end

  defp check_policy(_, _, _), do: false

  @doc """
  Scopes an Ecto query based on the user's policies for a specific permission.
  """
  @spec scope_query(Ecto.Query.t(), map() | nil, String.t()) :: Ecto.Query.t()
  def scope_query(query, nil, _permission), do: where(query, [q], false)

  def scope_query(query, user, permission) do
    cond do
      "admin" in user.role.permissions ->
        query

      permission in user.role.permissions ->
        policies = Map.get(user.role.policies || %{}, permission, [])
        apply_query_policies(query, policies, user)

      true ->
        where(query, [q], false)
    end
  end

  defp apply_query_policies(query, [], _user), do: query

  defp apply_query_policies(query, policies, user) do
    Enum.reduce(policies, query, fn policy, q -> apply_query_policy(q, policy, user) end)
  end

  defp apply_query_policy(query, "own_only", user) do
    where(query, [q], q.owner_id == ^user.id)
  end

  defp apply_query_policy(query, "not_published", _user) do
    where(query, [q], q.is_published == false)
  end

  defp apply_query_policy(query, "only_published", _user) do
    where(query, [q], q.is_published == true)
  end

  defp apply_query_policy(query, "published_or_owner", user) do
    where(query, [q], q.is_published == true or q.owner_id == ^user.id)
  end
end
