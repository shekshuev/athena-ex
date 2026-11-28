defmodule Athena.Content.CodeChallengeLanguageExpansionTest do
  use ExUnit.Case, async: true

  alias Athena.Content.CodeChallenge
  alias Ecto.Changeset

  test "new challenges default to Python" do
    changeset = CodeChallenge.changeset(%CodeChallenge{}, %{})
    assert changeset.valid?
    assert Changeset.get_field(changeset, :language) == "python3"
  end

  for language <- ~w(python3 cpp sql) do
    test "editing an existing #{language} challenge preserves its explicit language" do
      original = %CodeChallenge{
        language: unquote(language),
        initial_code: "existing source",
        setup_sql: "SELECT 1"
      }

      changeset =
        CodeChallenge.changeset(original, %{"time_limit" => "2.0", "body" => %{"type" => "doc"}})

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :language)
      updated = Changeset.apply_changes(changeset)
      assert updated.language == original.language
      assert updated.initial_code == original.initial_code
      assert updated.setup_sql == original.setup_sql
      assert updated.time_limit == 2.0
      assert original.time_limit == 1.0
    end
  end
end
