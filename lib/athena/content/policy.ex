defmodule Athena.Content.Policy do
  @moduledoc """
  Centralized policy engine for determining content access.
  Evaluates visibility status, global access rules, and cohort-specific overrides.
  """

  alias Athena.Identity.Account
  alias Athena.Content.{Block, Section}

  @doc """
  Determines if the given user is authorized to view the item.
  Accepts an optional list of `CohortSchedule` overrides fetched from the Learning context.
  """
  @spec can_view?(Account.t() | :all | nil, map(), list()) :: boolean()
  def can_view?(user_or_mode, item, overrides \\ [])

  def can_view?(:all, _item, _overrides), do: true

  def can_view?(user, item, overrides) do
    evaluate_visibility(user, item, overrides)
  end

  @doc false
  defp evaluate_visibility(user, item, overrides) do
    override = find_override(item, overrides)
    effective_visibility = (override && override.visibility) || item.visibility

    handle_visibility(effective_visibility, user, item, override, overrides)
  end

  defp find_override(%Block{id: id}, overrides) do
    Enum.find(overrides, &(&1.resource_type == :block and &1.resource_id == id))
  end

  defp find_override(%Section{id: id}, overrides) do
    Enum.find(overrides, &(&1.resource_type == :section and &1.resource_id == id))
  end

  defp find_override(_, _overrides), do: nil

  defp handle_visibility(:hidden, _user, _item, _override, _overrides), do: false

  defp handle_visibility(:enrolled, _user, _item, _override, _overrides), do: true

  defp handle_visibility(:restricted, _user, item, override, _overrides) do
    check_rules(item, override)
  end

  defp handle_visibility(:inherit, user, item, _override, overrides) do
    section = Athena.Repo.get(Section, item.section_id)
    evaluate_visibility(user, section, overrides)
  end

  @doc false
  defp check_rules(item, override) do
    rules = Map.get(item, :access_rules)

    unlock_at = if override, do: override.unlock_at, else: rules && rules.unlock_at
    lock_at = if override, do: override.lock_at, else: rules && rules.lock_at

    check_time(unlock_at, lock_at)
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
end
