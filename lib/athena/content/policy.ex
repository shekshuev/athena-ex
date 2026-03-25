defmodule Athena.Content.Policy do
  @moduledoc """
  Centralized policy engine for determining content access.

  Evaluates whether a user can view a specific content item (such as a Section or Block)
  based on the item's visibility status, and any dynamic access rules (like time boundaries 
  or specific role requirements).
  """

  alias Athena.Identity.Account
  alias Athena.Content.AccessRules

  @doc """
  Determines if the given user is authorized to view the item.

  - Passing `:all` bypasses all checks (used exclusively in Studio/Builder).
  - Passing an `Account` strictly evaluates student-facing rules. This allows 
    admins to experience the course exactly as a student would in the Player.
  """
  @spec can_view?(Account.t() | :all | nil, map()) :: boolean()
  def can_view?(:all, _item), do: true

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
  defp check_time(unlock_at, lock_at) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix()

    unlocked? =
      case parse_to_unix(unlock_at) do
        nil -> true
        target_unix -> now_unix >= target_unix
      end

    locked? =
      case parse_to_unix(lock_at) do
        nil -> false
        target_unix -> now_unix >= target_unix
      end

    unlocked? and not locked?
  end

  defp parse_to_unix(nil), do: nil
  defp parse_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp parse_to_unix(%NaiveDateTime{} = ndt),
    do: DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()

  defp parse_to_unix(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        DateTime.to_unix(dt)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
          _ -> nil
        end
    end
  end

  defp parse_to_unix(_), do: nil

  @doc false
  defp check_role(_user, []), do: true

  @doc false
  defp check_role(user, allowed_roles) when is_list(allowed_roles) do
    if user and user.role do
      user.role.name in allowed_roles
    else
      false
    end
  end

  @doc false
  defp enrolled?(_user), do: true
end
