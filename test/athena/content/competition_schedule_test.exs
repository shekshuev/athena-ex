defmodule Athena.Content.CompetitionScheduleTest do
  @moduledoc """
  Covers the `starts_at`/`ends_at` run window on courses: the changeset
  validation, and how `Courses.list_competitions_by_phase/0` buckets
  published competitions for the student dashboard.
  """
  use Athena.DataCase, async: true

  alias Athena.Content.Course
  alias Athena.Content.Courses

  import Athena.Factory

  defp competition(attrs) do
    insert(:course, Keyword.merge([type: :competition, status: :published], attrs))
  end

  defp days(n), do: DateTime.add(DateTime.utc_now(:second), n, :day)

  describe "Course.changeset/2 schedule validation" do
    test "accepts a window with no dates at all" do
      changeset = Course.changeset(%Course{}, %{title: "Open", owner_id: Ecto.UUID.generate()})

      assert changeset.valid?
    end

    test "accepts ends_at after starts_at" do
      changeset =
        Course.changeset(%Course{}, %{
          title: "Olympiad",
          owner_id: Ecto.UUID.generate(),
          starts_at: days(1),
          ends_at: days(2)
        })

      assert changeset.valid?
    end

    test "rejects ends_at before starts_at" do
      changeset =
        Course.changeset(%Course{}, %{
          title: "Olympiad",
          owner_id: Ecto.UUID.generate(),
          starts_at: days(2),
          ends_at: days(1)
        })

      refute changeset.valid?
      assert "must be after the start date" in errors_on(changeset).ends_at
    end

    test "rejects ends_at equal to starts_at" do
      at = days(1)

      changeset =
        Course.changeset(%Course{}, %{
          title: "Olympiad",
          owner_id: Ecto.UUID.generate(),
          starts_at: at,
          ends_at: at
        })

      refute changeset.valid?
    end

    test "accepts an open-ended window" do
      changeset =
        Course.changeset(%Course{}, %{
          title: "Olympiad",
          owner_id: Ecto.UUID.generate(),
          starts_at: days(1)
        })

      assert changeset.valid?
    end
  end

  describe "list_competitions_by_phase/0" do
    test "a competition with no dates is always current" do
      course = competition(starts_at: nil, ends_at: nil)

      assert %{current: current} = Courses.list_competitions_by_phase()
      assert course.id in Enum.map(current, & &1.id)
    end

    test "an open window is current" do
      course = competition(starts_at: days(-1), ends_at: days(1))

      %{current: current} = Courses.list_competitions_by_phase()
      assert course.id in Enum.map(current, & &1.id)
    end

    test "a competition starting within a month is upcoming" do
      course = competition(starts_at: days(10), ends_at: days(11))

      %{upcoming: upcoming, current: current} = Courses.list_competitions_by_phase()
      assert course.id in Enum.map(upcoming, & &1.id)
      refute course.id in Enum.map(current, & &1.id)
    end

    test "a competition that ended within the last month is past" do
      course = competition(starts_at: days(-10), ends_at: days(-5))

      %{past: past, current: current} = Courses.list_competitions_by_phase()
      assert course.id in Enum.map(past, & &1.id)
      refute course.id in Enum.map(current, & &1.id)
    end

    test "a competition starting more than a month out is in no bucket" do
      course = competition(starts_at: days(45), ends_at: days(46))

      phases = Courses.list_competitions_by_phase()
      refute course.id in all_ids(phases)
    end

    test "a competition that ended more than a month ago is in no bucket" do
      course = competition(starts_at: days(-60), ends_at: days(-45))

      phases = Courses.list_competitions_by_phase()
      refute course.id in all_ids(phases)
    end

    test "a draft competition is never listed, whatever its window" do
      course = competition(status: :draft, starts_at: days(-1), ends_at: days(1))

      phases = Courses.list_competitions_by_phase()
      refute course.id in all_ids(phases)
    end

    test "a standard course is never listed, whatever its window" do
      course = insert(:course, type: :standard, status: :published, starts_at: days(-1))

      phases = Courses.list_competitions_by_phase()
      refute course.id in all_ids(phases)
    end

    test "a soft-deleted competition is never listed" do
      course =
        competition(starts_at: days(-1), ends_at: days(1), deleted_at: DateTime.utc_now(:second))

      phases = Courses.list_competitions_by_phase()
      refute course.id in all_ids(phases)
    end

    test "always returns all three keys, even with nothing to show" do
      assert %{upcoming: _, current: _, past: _} = Courses.list_competitions_by_phase()
    end
  end

  defp all_ids(phases) do
    phases |> Map.values() |> List.flatten() |> Enum.map(& &1.id)
  end
end
