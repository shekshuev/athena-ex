defmodule Athena.Content.Policy do
  @moduledoc """
  Centralized policy engine for determining content access.
  Evaluates visibility status, global access rules, and cohort-specific overrides.
  """

  alias Athena.Identity.Account
  alias Athena.Repo
  alias Athena.Content.{Block, Section, EngagementRule}

  @doc """
  Determines if the given user is authorized to view the item.
  Accepts an optional list of `CohortSchedule` overrides fetched from the Learning context.
  """
  @spec can_view?(Account.t() | :all | nil, map(), list(), keyword()) :: boolean()
  def can_view?(user_or_mode, item, overrides \\ [], opts \\ [])

  def can_view?(:all, _item, _overrides, _opts), do: true

  def can_view?(user, item, overrides, opts) do
    evaluate_visibility(user, item, overrides, opts)
  end

  @doc false
  defp evaluate_visibility(user, item, overrides, opts) do
    override = find_override(item, overrides)
    effective_visibility = (override && override.visibility) || item.visibility

    handle_visibility(effective_visibility, user, item, override, overrides, opts)
  end

  defp find_override(%Block{id: id}, overrides) do
    Enum.find(overrides, &(&1.resource_type == :block and &1.resource_id == id))
  end

  defp find_override(%Section{id: id}, overrides) do
    Enum.find(overrides, &(&1.resource_type == :section and &1.resource_id == id))
  end

  defp find_override(_, _overrides), do: nil

  defp handle_visibility(:hidden, _user, _item, _override, _overrides, _opts), do: false

  defp handle_visibility(:enrolled, _user, _item, _override, _overrides, _opts), do: true

  defp handle_visibility(:restricted, _user, item, override, _overrides, opts) do
    check_rules(item, override, opts)
  end

  defp handle_visibility(:inherit, user, item, _override, overrides, opts) do
    section = Repo.get(Section, item.section_id)
    evaluate_visibility(user, section, overrides, opts)
  end

  @doc false
  defp check_rules(item, override, opts) do
    rules = Map.get(item, :access_rules)

    unlock_at = if override, do: override.unlock_at, else: rules && rules.unlock_at
    lock_at = if override, do: override.lock_at, else: rules && rules.lock_at

    check_time(unlock_at, lock_at, opts)
  end

  @doc false
  defp check_time(unlock_at, lock_at, opts) do
    if Keyword.get(opts, :ignore_schedule?, false) do
      true
    else
      check_time(unlock_at, lock_at)
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

  @doc """
  Resolves a block's effective engagement-tracking thresholds through the
  same "specific overrides general" cascade already used for access rules:
  a value set directly on the block wins; otherwise the block's section
  supplies the default; otherwise the application-wide config default
  applies (see `config :athena, Athena.Engagement` in `config/config.exs`).

  A `nil` field on `Block.engagement_rule`/`Section.engagement_rule` means
  "inherit from the next level up", not "disabled" - that's what makes the
  cascade work field-by-field rather than all-or-nothing.
  """
  @spec resolve_engagement_rule(Block.t(), Section.t()) :: %{
          expected_seconds: pos_integer() | nil,
          fast_ratio_threshold: float(),
          nudge_enabled: boolean()
        }
  def resolve_engagement_rule(%Block{} = block, %Section{} = section) do
    block_rule = block.engagement_rule || %EngagementRule{}
    section_rule = section.engagement_rule || %EngagementRule{}
    config = Application.get_env(:athena, Athena.Engagement, [])

    %{
      expected_seconds:
        first_non_nil([
          block_rule.expected_seconds,
          section_rule.expected_seconds,
          Keyword.get(config, :default_expected_seconds)
        ]),
      fast_ratio_threshold:
        first_non_nil([
          block_rule.fast_ratio_threshold,
          section_rule.fast_ratio_threshold,
          Keyword.get(config, :default_fast_ratio_threshold)
        ]) || 0.4,
      nudge_enabled: resolve_nudge_enabled(block_rule.nudge_enabled, section_rule.nudge_enabled)
    }
  end

  @doc false
  defp first_non_nil(values), do: Enum.find(values, &(&1 != nil))

  # A plain `||` chain would be wrong here: `false` is a meaningful resolved
  # value ("explicitly opted out"), not an absent one like `nil` - so it must
  # not fall through to the `true` default the way `first_non_nil(...) ||
  # true` would (Elixir's `||` treats `false` itself as falsy).
  @doc false
  defp resolve_nudge_enabled(nil, nil), do: true
  defp resolve_nudge_enabled(nil, section_value), do: section_value
  defp resolve_nudge_enabled(block_value, _section_value), do: block_value
end
