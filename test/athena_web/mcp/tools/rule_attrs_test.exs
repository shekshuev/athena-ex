defmodule AthenaWeb.MCP.Tools.RuleAttrsTest do
  use ExUnit.Case, async: true

  alias AthenaWeb.MCP.Tools.RuleAttrs

  describe "access_rules/1" do
    test "backfills reset_waterline to false, not nil, when omitted" do
      assert RuleAttrs.access_rules(%{"unlock_at" => "2026-01-01T00:00:00Z"}) == %{
               "unlock_at" => "2026-01-01T00:00:00Z",
               "lock_at" => nil,
               "reset_waterline" => false
             }
    end

    test "passes nil through unchanged" do
      assert RuleAttrs.access_rules(nil) == nil
    end
  end

  describe "completion_rule/1" do
    test "backfills type to \"none\" when omitted" do
      assert RuleAttrs.completion_rule(%{}) == %{
               "type" => "none",
               "button_text" => nil,
               "min_score" => nil
             }
    end

    test "clears button_text when switching to pass_auto_grade without it" do
      # Regression: `embeds_one ..., on_replace: :update` merges cast/3 onto
      # the EXISTING embed, so a payload that only mentions `type`/`min_score`
      # would otherwise leave a stale `button_text` from a prior "button" rule.
      normalized = RuleAttrs.completion_rule(%{"type" => "pass_auto_grade", "min_score" => 80})

      assert normalized == %{
               "type" => "pass_auto_grade",
               "button_text" => nil,
               "min_score" => 80
             }
    end
  end

  describe "engagement_rule/1" do
    test "all fields default to nil when omitted" do
      assert RuleAttrs.engagement_rule(%{}) == %{
               "expected_seconds" => nil,
               "nudge_enabled" => nil,
               "fast_ratio_threshold" => nil
             }
    end
  end

  describe "normalize/1" do
    test "only touches keys actually present in attrs" do
      attrs = %{
        "title" => "Intro",
        "completion_rule" => %{"type" => "button", "button_text" => "Go"}
      }

      assert RuleAttrs.normalize(attrs) == %{
               "title" => "Intro",
               "completion_rule" => %{
                 "type" => "button",
                 "button_text" => "Go",
                 "min_score" => nil
               }
             }
    end

    test "leaves attrs without any rule keys unchanged" do
      attrs = %{"title" => "Intro"}
      assert RuleAttrs.normalize(attrs) == attrs
    end
  end
end
