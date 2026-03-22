defmodule Athena.Content.Policy do
  @moduledoc """
  Centralized policy engine for determining content access.

  Evaluates whether a user can view a specific content item (such as a Section or Block)
  based on their global permissions, the item's visibility status, and any dynamic 
  access rules (like time boundaries or specific role requirements).
  """

  alias Athena.Identity.{Account, Role}
  alias Athena.Content.AccessRules

  @doc """
  Determines if the given user is authorized to view the item.

  Users with the `"admin"` permission always have access. For other users, 
  access is evaluated against the item's `:visibility` and `:access_rules`.
  """
  @spec can_view?(Account.t() | nil, map()) :: boolean()
  def can_view?(%Account{role: %Role{permissions: perms}} = user, item) do
    if "admin" in (perms || []) do
      true
    else
      evaluate_visibility(user, item)
    end
  end

  def can_view?(user, item) do
    evaluate_visibility(user, item)
  end

  @doc false
  defp evaluate_visibility(user, %Athena.Content.Block{visibility: :inherit} = block) do
    section = Athena.Repo.get(Athena.Content.Section, block.section_id)
    evaluate_visibility(user, section)
  end

  @doc false
  defp evaluate_visibility(user, %{visibility: visibility, access_rules: rules}) do
    case visibility do
      :hidden -> false
      :public -> true
      :enrolled -> enrolled?(user)
      :restricted -> check_rules(user, rules)
    end
  end

  @doc false
  defp check_rules(_user, nil), do: true

  @doc false
  defp check_rules(user, %AccessRules{} = rules) do
    with true <- check_time(rules.unlock_at, rules.lock_at),
         true <- check_role(user, rules.allowed_roles) do
      true
    else
      _ -> false
    end
  end

  @doc false
  defp check_time(nil, nil), do: true

  @doc false
  defp check_time(unlock_at, lock_at) do
    now = DateTime.utc_now()

    unlocked? = if unlock_at, do: DateTime.compare(now, unlock_at) != :lt, else: true
    not_locked? = if lock_at, do: DateTime.compare(now, lock_at) == :lt, else: true

    unlocked? and not_locked?
  end

  @doc false
  defp check_role(_user, []), do: true

  @doc false
  defp check_role(user, allowed_roles) when is_list(allowed_roles) do
    user.role.name in allowed_roles
  end

  @doc false
  defp enrolled?(_user), do: true
end
