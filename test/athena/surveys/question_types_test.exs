defmodule Athena.Surveys.QuestionTypesTest do
  @moduledoc """
  The per-type config contract. These run against `SurveyQuestion.changeset/2`
  rather than the config schemas directly, because the thing that matters is
  that an invalid config cannot be *saved* - the schemas are only reachable
  through that changeset.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Surveys.{QuestionTypes, SurveyQuestion}

  defp changeset(type, config, overrides \\ %{}) do
    survey = insert(:survey)

    SurveyQuestion.changeset(
      %SurveyQuestion{},
      Map.merge(
        %{
          "survey_id" => survey.id,
          "type" => type,
          "body" => tiptap_doc("Question"),
          "config" => config
        },
        overrides
      )
    )
  end

  describe "the registry" do
    test "every type has a measurement level, a default config and a changeset" do
      for type <- QuestionTypes.all() do
        assert QuestionTypes.measurement(type) in [:nominal, :ordinal, :interval, :ratio, :text]
        assert is_map(QuestionTypes.default_config(type))
        assert %Ecto.Changeset{} = QuestionTypes.config_changeset(type, %{})
      end
    end

    test "a freshly added question of any type is valid with its default config" do
      for type <- QuestionTypes.all() do
        cs = changeset(type, QuestionTypes.default_config(type))

        assert cs.valid?, "#{type} default config was invalid: #{inspect(errors_on(cs))}"
      end
    end

    test "only the quantitative types claim a mean is defined" do
      assert QuestionTypes.quantitative?(:scale)
      assert QuestionTypes.quantitative?(:numeric)
      assert QuestionTypes.quantitative?(:nps)
      refute QuestionTypes.quantitative?(:single_choice)
      refute QuestionTypes.quantitative?(:open_text)
      refute QuestionTypes.quantitative?(:ranking)
    end

    test "only :multi_scale writes one answer row per sub-item" do
      assert QuestionTypes.multi_row?(:multi_scale)

      for type <- QuestionTypes.all() -- [:multi_scale] do
        refute QuestionTypes.multi_row?(type)
      end
    end
  end

  describe "config validation is enforced on save" do
    test "a choice question needs at least two options" do
      {config, _ids} = choice_config(["Only one"])

      cs = changeset(:single_choice, config)

      refute cs.valid?
      assert "options: must have at least 2 options" in errors_on(cs).config
    end

    test "a nested option error is reported, not silently dropped" do
      # The `Block` content pattern reduces over `errors` alone, where a
      # `cast_embed` child's errors never appear - so this config would save.
      config = %{
        "options" => [
          %{"id" => Ecto.UUID.generate(), "text" => "Fine"},
          %{"id" => Ecto.UUID.generate(), "text" => ""}
        ]
      }

      cs = changeset(:single_choice, config)

      refute cs.valid?
      assert "options.1.text: can't be blank" in errors_on(cs).config
    end

    test "a scale cannot be inverted" do
      cs = changeset(:scale, %{"min" => 5, "max" => 1, "step" => 1})

      refute cs.valid?
      assert "max: must be greater than the minimum" in errors_on(cs).config
    end

    test "point labels must cover every scale point when given at all" do
      bad = changeset(:scale, %{"min" => 1, "max" => 5, "step" => 1, "point_labels" => ~w(a b)})
      refute bad.valid?
      assert "point_labels: must have one label per scale point" in errors_on(bad).config

      good =
        changeset(:scale, %{"min" => 1, "max" => 5, "step" => 1, "point_labels" => ~w(a b c d e)})

      assert good.valid?

      poles_only = changeset(:scale, %{"min" => 1, "max" => 5, "step" => 1, "point_labels" => []})
      assert poles_only.valid?
    end

    test "a matrix needs at least one row" do
      cs = changeset(:multi_scale, %{"rows" => [], "min" => 1, "max" => 5, "step" => 1})

      refute cs.valid?
      assert "rows: must have at least 1 row" in errors_on(cs).config
    end

    test "ranking rejects a top-N larger than the item list" do
      {config, _ids} = choice_config(["A", "B"])
      config = config |> Map.put("items", config["options"]) |> Map.put("max_ranked", 5)

      cs = changeset(:ranking, config)

      refute cs.valid?
      assert "max_ranked: cannot exceed the number of items" in errors_on(cs).config
    end

    test "multiple choice rejects a selection range that cannot be satisfied" do
      {config, _ids} = choice_config(["A", "B", "C"])
      config = Map.merge(config, %{"min_select" => 3, "max_select" => 2})

      cs = changeset(:multiple_choice, config)

      refute cs.valid?
      assert "max_select: must be at least the minimum" in errors_on(cs).config
    end
  end

  describe "stored configs" do
    test "are string-keyed after the JSON round-trip, like Block content" do
      {:ok, question} =
        :scale
        |> changeset(%{"min" => 1, "max" => 7, "step" => 2, "min_label" => "Never"})
        |> Repo.insert()

      assert question.config["min"] == 1
      assert question.config["max"] == 7
      assert question.config["min_label"] == "Never"

      # No atom keys and no struct residue survive the round-trip.
      assert Enum.all?(Map.keys(question.config), &is_binary/1)
      refute Map.has_key?(question.config, "__struct__")
    end

    test "unspecified fields come back as the schema's declared defaults" do
      {:ok, question} = :open_text |> changeset(%{}) |> Repo.insert()

      assert question.config["multiline"] == true
      assert question.config["max_length"] == 2000
    end
  end
end
