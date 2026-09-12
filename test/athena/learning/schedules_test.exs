defmodule Athena.Learning.SchedulesTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Schedules
  alias Athena.Learning.CohortSchedule
  alias Athena.Learning.Cohorts
  import Athena.Factory

  setup do
    admin_role = insert(:role, permissions: ["admin"])
    admin = insert(:account, role: admin_role)

    inst_role =
      insert(:role,
        permissions: ["cohorts.read", "cohorts.update", "courses.read", "courses.update"],
        policies: %{
          "cohorts.read" => ["own_only"],
          "cohorts.update" => ["own_only"],
          "courses.read" => ["own_only"],
          "courses.update" => ["own_only"]
        }
      )

    instructor = insert(:account, role: inst_role)
    inst_profile = insert(:instructor, owner_id: instructor.id)

    %{admin: admin, instructor: instructor, inst_profile: inst_profile}
  end

  describe "get_student_overrides/3" do
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

  describe "set_override/4" do
    test "creates a new override if it doesn't exist", %{admin: admin} do
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

      assert {:ok, %CohortSchedule{} = schedule} =
               Schedules.set_override(admin, cohort, course, attrs)

      assert schedule.resource_type == :section
      assert schedule.unlock_at == now
    end

    test "updates an existing override via UPSERT (on_conflict)", %{admin: admin} do
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

      assert {:ok, %CohortSchedule{} = updated} =
               Schedules.set_override(admin, cohort, course, attrs)

      assert updated.unlock_at == new_unlock
      assert Athena.Repo.aggregate(CohortSchedule, :count) == 1
    end

    test "returns error changeset on invalid dates", %{admin: admin} do
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

      assert {:error, changeset} = Schedules.set_override(admin, cohort, course, attrs)
      assert "must be after the unlock time" in errors_on(changeset).lock_at
    end
  end

  describe "clear_override/5" do
    test "deletes the specific override", %{admin: admin} do
      cohort = insert(:cohort)
      course = insert(:course)

      schedule =
        insert(:cohort_schedule,
          cohort_id: cohort.id,
          course_id: course.id,
          resource_type: :block
        )

      assert {:ok, {1, nil}} =
               Schedules.clear_override(
                 admin,
                 cohort,
                 course,
                 schedule.resource_type,
                 schedule.resource_id
               )

      assert Athena.Repo.all(CohortSchedule) == []
    end

    test "does not delete other overrides", %{admin: admin} do
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

      assert {:ok, {1, nil}} =
               Schedules.clear_override(
                 admin,
                 cohort,
                 course,
                 schedule.resource_type,
                 schedule.resource_id
               )

      leftovers = Athena.Repo.all(CohortSchedule)
      assert length(leftovers) == 1
      assert hd(leftovers).id == other.id
    end
  end

  describe "Permissions & ACL (Policies: own_only)" do
    setup %{instructor: instructor} do
      my_cohort = insert(:cohort, owner_id: instructor.id)
      other_cohort = insert(:cohort, owner_id: Ecto.UUID.generate())

      my_course = insert(:course, owner_id: instructor.id)
      other_course = insert(:course, owner_id: Ecto.UUID.generate())

      %{
        my_cohort: my_cohort,
        other_cohort: other_cohort,
        my_course: my_course,
        other_course: other_course
      }
    end

    test "allows override if instructor owns the cohort (but not course)", %{
      instructor: instructor,
      my_cohort: cohort,
      other_course: course
    } do
      attrs = %{
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :section,
        resource_id: Ecto.UUID.generate()
      }

      assert {:ok, _} = Schedules.set_override(instructor, cohort, course, attrs)
    end

    test "allows override if instructor owns the course (but not cohort)", %{
      instructor: instructor,
      other_cohort: cohort,
      my_course: course
    } do
      attrs = %{
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :section,
        resource_id: Ecto.UUID.generate()
      }

      assert {:ok, _} = Schedules.set_override(instructor, cohort, course, attrs)
    end

    test "allows override if instructor is a CO-INSTRUCTOR in the cohort", %{
      admin: admin,
      instructor: instructor,
      inst_profile: inst_profile,
      other_cohort: cohort,
      other_course: course
    } do
      Cohorts.update_cohort(admin, cohort, %{"instructor_ids" => [inst_profile.id]})

      attrs = %{
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :section,
        resource_id: Ecto.UUID.generate()
      }

      assert {:ok, _} = Schedules.set_override(instructor, cohort, course, attrs)
    end

    test "returns forbidden if instructor owns NEITHER cohort nor course and is NOT a co-instructor",
         %{
           instructor: instructor,
           other_cohort: cohort,
           other_course: course
         } do
      attrs = %{
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :section,
        resource_id: Ecto.UUID.generate()
      }

      assert {:error, :forbidden} = Schedules.set_override(instructor, cohort, course, attrs)
    end

    test "returns forbidden if co-instructor lacks 'cohorts.update' permission (e.g. read-only observer)",
         %{
           admin: admin,
           other_cohort: cohort,
           other_course: course
         } do
      observer_role = insert(:role, permissions: ["cohorts.read", "courses.read"])
      observer = insert(:account, role: observer_role)
      observer_profile = insert(:instructor, owner_id: observer.id)

      Cohorts.update_cohort(admin, cohort, %{"instructor_ids" => [observer_profile.id]})

      attrs = %{
        cohort_id: cohort.id,
        course_id: course.id,
        resource_type: :section,
        resource_id: Ecto.UUID.generate()
      }

      assert {:error, :forbidden} = Schedules.set_override(observer, cohort, course, attrs)

      assert {:error, :forbidden} =
               Schedules.clear_override(observer, cohort, course, :section, Ecto.UUID.generate())
    end
  end

  describe "list_upcoming_deadlines/2" do
    test "returns future lock deadlines for cohorts the account belongs to" do
      student = insert(:account)
      cohort = insert(:cohort)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      schedule =
        insert(:cohort_schedule, cohort_id: cohort.id, lock_at: future, unlock_at: nil)

      assert [result] = Schedules.list_upcoming_deadlines(student.id)
      assert result.id == schedule.id
    end

    test "excludes deadlines that already passed" do
      student = insert(:account)
      cohort = insert(:cohort)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
      insert(:cohort_schedule, cohort_id: cohort.id, lock_at: past)

      assert Schedules.list_upcoming_deadlines(student.id) == []
    end

    test "excludes deadlines from cohorts the account does not belong to" do
      student = insert(:account)
      other_cohort = insert(:cohort)

      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      insert(:cohort_schedule, cohort_id: other_cohort.id, lock_at: future)

      assert Schedules.list_upcoming_deadlines(student.id) == []
    end

    test "respects the :limit option and orders by lock_at ascending" do
      student = insert(:account)
      cohort = insert(:cohort)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      now = DateTime.utc_now()

      soon =
        insert(:cohort_schedule,
          cohort_id: cohort.id,
          lock_at: DateTime.add(now, 1800, :second) |> DateTime.truncate(:second)
        )

      later =
        insert(:cohort_schedule,
          cohort_id: cohort.id,
          lock_at: DateTime.add(now, 7200, :second) |> DateTime.truncate(:second)
        )

      assert [first, second] = Schedules.list_upcoming_deadlines(student.id)
      assert first.id == soon.id
      assert second.id == later.id

      assert [_one] = Schedules.list_upcoming_deadlines(student.id, limit: 1)
    end
  end
end
