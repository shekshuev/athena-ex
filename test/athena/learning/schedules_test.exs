defmodule Athena.Learning.SchedulesTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Schedules
  alias Athena.Learning.CohortSchedule
  import Athena.Factory

  describe "get_student_overrides/2" do
    test "returns overrides for cohorts the student is a member of in the given course" do
      student = insert(:account)
      cohort = insert(:cohort)
      other_cohort = insert(:cohort)
      course = insert(:course)
      other_course = insert(:course)

      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      valid_schedule = insert(:cohort_schedule, cohort_id: cohort.id, course_id: course.id)
      insert(:cohort_schedule, cohort_id: cohort.id, course_id: other_course.id)
      insert(:cohort_schedule, cohort_id: other_cohort.id, course_id: course.id)

      overrides = Schedules.get_student_overrides(student.id, course.id, cohort.id)

      assert length(overrides) == 1
      assert hd(overrides).id == valid_schedule.id
    end
  end

  describe "list_cohort_course_overrides/2" do
    test "returns all overrides for a specific cohort and course" do
      cohort = insert(:cohort)
      course = insert(:course)
      other_course = insert(:course)

      s1 = insert(:cohort_schedule, cohort_id: cohort.id, course_id: course.id)
      s2 = insert(:cohort_schedule, cohort_id: cohort.id, course_id: course.id)

      insert(:cohort_schedule, cohort_id: cohort.id, course_id: other_course.id)

      overrides = Schedules.list_cohort_course_overrides(cohort.id, course.id)

      assert length(overrides) == 2
      ids = Enum.map(overrides, & &1.id)
      assert s1.id in ids
      assert s2.id in ids
    end
  end

  describe "set_override/1" do
    test "creates a new override if it doesn't exist" do
      cohort = insert(:cohort)
      course = insert(:course)
      resource_id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :section,
        resource_id: resource_id,
        unlock_at: now
      }

      assert {:ok, %CohortSchedule{} = schedule} = Schedules.set_override(attrs)
      assert schedule.resource_type == :section
      assert schedule.unlock_at == now
    end

    test "updates an existing override via UPSERT (on_conflict)" do
      cohort = insert(:cohort)
      course = insert(:course)
      resource_id = Ecto.UUID.generate()

      insert(:cohort_schedule,
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :block,
        resource_id: resource_id,
        unlock_at: nil,
        lock_at: nil
      )

      new_unlock = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        "cohort_id" => cohort.id,
        "course_id" => course.id,
        "resource_type" => "block",
        "resource_id" => resource_id,
        "unlock_at" => new_unlock,
        "lock_at" => nil
      }

      assert {:ok, %CohortSchedule{} = updated} = Schedules.set_override(attrs)

      assert updated.unlock_at == new_unlock
      assert Athena.Repo.aggregate(CohortSchedule, :count) == 1
    end

    test "returns error changeset on invalid dates" do
      cohort = insert(:cohort)
      course = insert(:course)
      now = DateTime.utc_now()
      past = DateTime.add(now, -1, :day)

      attrs = %{
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :block,
        resource_id: Ecto.UUID.generate(),
        unlock_at: now,
        lock_at: past
      }

      assert {:error, changeset} = Schedules.set_override(attrs)
      assert "must be after the unlock time" in errors_on(changeset).lock_at
    end
  end

  describe "clear_override/3" do
    test "deletes the specific override" do
      cohort = insert(:cohort)
      course = insert(:course)

      schedule =
        insert(:cohort_schedule,
          cohort_id: cohort.id,
          course_id: course.id,
          resource_type: :block
        )

      assert {1, nil} =
               Schedules.clear_override(
                 schedule.cohort_id,
                 schedule.resource_type,
                 schedule.resource_id
               )

      assert Athena.Repo.all(CohortSchedule) == []
    end

    test "does not delete other overrides" do
      cohort = insert(:cohort)
      course = insert(:course)

      schedule =
        insert(:cohort_schedule,
          cohort_id: cohort.id,
          course_id: course.id,
          resource_type: :section
        )

      other =
        insert(:cohort_schedule,
          cohort_id: cohort.id,
          course_id: course.id,
          resource_type: :section,
          resource_id: Ecto.UUID.generate()
        )

      assert {1, nil} =
               Schedules.clear_override(
                 schedule.cohort_id,
                 schedule.resource_type,
                 schedule.resource_id
               )

      leftovers = Athena.Repo.all(CohortSchedule)
      assert length(leftovers) == 1
      assert hd(leftovers).id == other.id
    end
  end
end
