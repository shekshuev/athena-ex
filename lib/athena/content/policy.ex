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
    resource_type =
      case item do
        %Block{} -> :block
        %Section{} -> :section
        _ -> nil
      end

    override =
      Enum.find(overrides, fn o ->
        o.resource_type == resource_type and o.resource_id == item.id
      end)

    effective_visibility = (override && override.visibility) || item.visibility

    case effective_visibility do
      :hidden ->
        false

      :enrolled ->
        true

      :restricted ->
        check_rules(item, override)

      :inherit ->
        section = Athena.Repo.get(Section, item.section_id)
        evaluate_visibility(user, section, overrides)
    end
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
