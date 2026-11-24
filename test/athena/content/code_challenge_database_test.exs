defmodule Athena.Content.CodeChallengeDatabaseTest do
  use ExUnit.Case, async: true
  alias Athena.Content.CodeChallenge

  test "old SQL content remains PostgreSQL and all configured engines round-trip" do
    old = CodeChallenge.changeset(%CodeChallenge{}, %{"language" => "sql"})
    assert old.valid?
    assert Ecto.Changeset.get_field(old, :database_engine) == "postgresql"

    for engine <- ["postgresql", "mysql", "clickhouse"] do
      changeset =
        CodeChallenge.changeset(%CodeChallenge{}, %{
          "language" => "sql",
          "database_engine" => engine
        })

      assert changeset.valid?
      content = changeset |> Ecto.Changeset.apply_changes() |> Jason.encode!() |> Jason.decode!()
      assert content["database_engine"] == engine
    end
  end

  test "rejects unknown engines on the server" do
    for engine <- ["mongodb", nil] do
      changeset =
        CodeChallenge.changeset(%CodeChallenge{}, %{
          "language" => "sql",
          "database_engine" => engine
        })

      refute changeset.valid?
      assert changeset.errors[:database_engine]
    end
  end
end
