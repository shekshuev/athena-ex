defmodule AthenaWeb.MCP.Tools.RuleAttrs do
  @moduledoc """
  Normalizes `access_rules`/`completion_rule`/`engagement_rule` payloads so
  they behave as a genuine full replacement, as documented in
  `athena://docs/progression-rules`.

  Without this, they wouldn't: `Athena.Content.Section`/`Block` declare
  these as `embeds_one ..., on_replace: :update`, which makes
  `Ecto.Changeset.cast_embed/3` build the new embed by running the CHILD
  changeset against the EXISTING embedded struct - any field the caller
  omits from their payload silently keeps its previous value instead of
  resetting to nil/default (e.g. switching `completion_rule` from
  `%{"type" => "button", "button_text" => "Continue"}` to
  `%{"type" => "pass_auto_grade", "min_score" => 80}` would otherwise leave
  the stale `button_text: "Continue"` in place, since the `pass_auto_grade`
  branch of `CompletionRule`'s own changeset never touches `button_text`).
  We backfill every known field explicitly (with the same default the
  schema itself would use for a brand new embed) before it ever reaches
  `cast_embed`, so a partial payload always fully replaces the embed.
  """

  @doc "Normalizes an `access_rules` payload, or passes through `nil` unchanged."
  def access_rules(nil), do: nil

  def access_rules(map) do
    %{
      "unlock_at" => Map.get(map, "unlock_at"),
      "lock_at" => Map.get(map, "lock_at"),
      "reset_waterline" => Map.get(map, "reset_waterline", false)
    }
  end

  @doc "Normalizes a `completion_rule` payload, or passes through `nil` unchanged."
  def completion_rule(nil), do: nil

  def completion_rule(map) do
    %{
      "type" => Map.get(map, "type", "none"),
      "button_text" => Map.get(map, "button_text"),
      "min_score" => Map.get(map, "min_score")
    }
  end

  @doc "Normalizes an `engagement_rule` payload, or passes through `nil` unchanged."
  def engagement_rule(nil), do: nil

  def engagement_rule(map) do
    %{
      "expected_seconds" => Map.get(map, "expected_seconds"),
      "nudge_enabled" => Map.get(map, "nudge_enabled"),
      "fast_ratio_threshold" => Map.get(map, "fast_ratio_threshold")
    }
  end

  @doc """
  Applies the matching normalizer to `attrs["access_rules"]`/
  `["completion_rule"]`/`["engagement_rule"]`, for whichever of those keys
  are actually present in `attrs` - a key that's absent is left untouched
  (the embed isn't mentioned at all, so the update leaves it alone).
  """
  def normalize(attrs) do
    attrs
    |> normalize_key("access_rules", &access_rules/1)
    |> normalize_key("completion_rule", &completion_rule/1)
    |> normalize_key("engagement_rule", &engagement_rule/1)
  end

  defp normalize_key(attrs, key, fun) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, fun.(value))
      :error -> attrs
    end
  end
end
