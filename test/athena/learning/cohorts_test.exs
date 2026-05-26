defmodule Athena.Learning.CohortsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Cohorts
  alias Athena.Learning.Cohort
  alias Athena.Learning.CohortMembership
  import Athena.Factory

  setup do
    admin_role =
      insert(:role,
        permissions: [
          "admin",
          "cohorts.read",
          "cohorts.create",
          "cohorts.update",
          "cohorts.delete"
        ]
      )

    admin = insert(:account, role: admin_role)

    inst_role =
      insert(:role,
        permissions: ["cohorts.read", "cohorts.create", "cohorts.update", "cohorts.delete"],
        policies: %{
          "cohorts.read" => ["own_only"],
          "cohorts.update" => ["own_only"],
          "cohorts.delete" => ["own_only"]
        }
      )

    inst1_account = insert(:account, role: inst_role)
    inst1_profile = insert(:instructor, owner_id: inst1_account.id)

    inst2_account = insert(:account, role: inst_role)
    inst2_profile = insert(:instructor, owner_id: inst2_account.id)

    %{
      admin: admin,
      inst1_account: inst1_account,
      inst1_profile: inst1_profile,
      inst2_account: inst2_account,
      inst2_profile: inst2_profile
    }
  end

  describe "list_cohorts/2 (With ACL)" do
    test "returns a paginated list of all cohorts for admin", %{admin: admin} do
      insert_list(3, :cohort)

      {:ok, {cohorts, meta}} = Cohorts.list_cohorts(admin, %{page: 1, page_size: 2})

      assert length(cohorts) == 2
      assert meta.total_count == 3
    end

    test "applies own_only policy so instructor sees only their cohorts", %{
      inst1_account: inst1_account,
      inst1_profile: inst1_profile,
      inst2_account: inst2_account,
      inst2_profile: inst2_profile
    } do
      {:ok, my_cohort} =
        Cohorts.create_cohort(inst1_account, %{
          "name" => "My Cohort",
          "instructor_ids" => [inst1_profile.id]
        })

      {:ok, _other_cohort} =
        Cohorts.create_cohort(inst2_account, %{
          "name" => "Other Cohort",
          "instructor_ids" => [inst2_profile.id]
        })

      {:ok, {fetched_cohorts, meta}} = Cohorts.list_cohorts(inst1_account, %{})

      assert length(fetched_cohorts) == 1
      assert hd(fetched_cohorts).id == my_cohort.id
      assert meta.total_count == 1
    end

    test "preloads and enriches instructors", %{
      admin: admin,
      inst1_account: account,
      inst1_profile: profile
    } do
      Cohorts.create_cohort(admin, %{"name" => "Bootcamp", "instructor_ids" => [profile.id]})

      {:ok, {fetched_cohorts, _meta}} = Cohorts.list_cohorts(admin, %{})

      fetched_cohort = hd(fetched_cohorts)
      assert length(fetched_cohort.instructors) == 1
      fetched_instructor = hd(fetched_cohort.instructors)

      assert fetched_instructor.id == profile.id
      assert fetched_instructor.account.login == account.login
    end
  end

  describe "get_cohort/2 (With ACL)" do
    test "returns the cohort with enriched instructors for admin", %{
      admin: admin,
      inst1_account: account,
      inst1_profile: profile
    } do
      {:ok, cohort} =
        Cohorts.create_cohort(admin, %{"name" => "Elixir 101", "instructor_ids" => [profile.id]})

      assert {:ok, fetched_cohort} = Cohorts.get_cohort(admin, cohort.id)
      assert fetched_cohort.id == cohort.id

      fetched_instructor = hd(fetched_cohort.instructors)
      assert fetched_instructor.account.login == account.login
    end

    test "returns cohort if instructor is assigned to it", %{
      inst1_account: account,
      inst1_profile: profile
    } do
      {:ok, cohort} =
        Cohorts.create_cohort(account, %{"name" => "My Group", "instructor_ids" => [profile.id]})

      assert {:ok, fetched_cohort} = Cohorts.get_cohort(account, cohort.id)
      assert fetched_cohort.id == cohort.id
    end

    test "returns not_found if instructor is not assigned to it (own_only)", %{
      inst1_account: account,
      inst2_account: other_account,
      inst2_profile: other_profile
    } do
      {:ok, cohort} =
        Cohorts.create_cohort(other_account, %{
          "name" => "Other Group",
          "instructor_ids" => [other_profile.id]
        })

      assert {:error, :not_found} = Cohorts.get_cohort(account, cohort.id)
    end

    test "returns not_found if cohort does not exist", %{admin: admin} do
      assert {:error, :not_found} = Cohorts.get_cohort(admin, Ecto.UUID.generate())
    end
  end

  describe "create_cohort/2" do
    test "creates a cohort with valid attributes", %{admin: admin} do
      attrs = %{"name" => "Winter Bootcamp", "description" => "Intensive course"}

      assert {:ok, %Cohort{} = cohort} = Cohorts.create_cohort(admin, attrs)
      assert cohort.name == "Winter Bootcamp"
      assert cohort.description == "Intensive course"
      assert cohort.owner_id == admin.id
    end

    test "creates a cohort and assigns instructors", %{admin: admin} do
      inst1 = insert(:instructor)
      inst2 = insert(:instructor)

      attrs = %{
        "name" => "Advanced Elixir",
        "instructor_ids" => [inst1.id, inst2.id]
      }

      assert {:ok, %Cohort{} = cohort} = Cohorts.create_cohort(admin, attrs)
      assert cohort.name == "Advanced Elixir"
      assert length(cohort.instructors) == 2
    end

    test "returns error changeset with invalid attributes", %{admin: admin} do
      assert {:error, changeset} = Cohorts.create_cohort(admin, %{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "returns unauthorized if user lacks permissions" do
      user_no_access = insert(:account, role: insert(:role, permissions: []))
      assert {:error, :unauthorized} = Cohorts.create_cohort(user_no_access, %{"name" => "Test"})
    end

    test "ignores owner_id injected via attrs (security check)", %{
      admin: admin,
      inst1_account: hacker
    } do
      attrs = %{
        "name" => "Hacked Cohort",
        "description" => "Trying to bypass owner",
        "owner_id" => admin.id
      }

      assert {:ok, %Cohort{} = cohort} = Cohorts.create_cohort(hacker, attrs)

      assert cohort.name == "Hacked Cohort"
      assert cohort.owner_id == hacker.id
      assert cohort.owner_id != admin.id
    end
  end

  describe "update_cohort/3" do
    test "updates cohort attributes", %{admin: admin} do
      cohort = insert(:cohort, name: "Old Name", owner_id: admin.id)

      assert {:ok, updated} = Cohorts.update_cohort(admin, cohort, %{"name" => "New Name"})
      assert updated.name == "New Name"
    end

    test "replaces assigned instructors", %{admin: admin} do
      inst1 = insert(:instructor)
      inst2 = insert(:instructor)

      {:ok, cohort} =
        Cohorts.create_cohort(admin, %{"name" => "Base", "instructor_ids" => [inst1.id]})

      assert {:ok, updated} =
               Cohorts.update_cohort(admin, cohort, %{"instructor_ids" => [inst2.id]})

      assert length(updated.instructors) == 1
      assert hd(updated.instructors).id == inst2.id
    end

    test "returns unauthorized if instructor tries to update someone else's cohort", %{
      admin: admin,
      inst1_account: inst_account
    } do
      cohort = insert(:cohort, name: "Admin's Cohort", owner_id: admin.id)

      assert {:error, :unauthorized} =
               Cohorts.update_cohort(inst_account, cohort, %{"name" => "Hacked"})
    end
  end

  describe "delete_cohort/2" do
    test "deletes the cohort", %{admin: admin} do
      cohort = insert(:cohort, owner_id: admin.id)
      assert {:ok, _deleted} = Cohorts.delete_cohort(admin, cohort)

      assert {:error, :not_found} = Cohorts.get_cohort(admin, cohort.id)
    end

    test "returns unauthorized if instructor tries to delete someone else's cohort", %{
      admin: admin,
      inst1_account: inst_account
    } do
      cohort = insert(:cohort, owner_id: admin.id)

      assert {:error, :unauthorized} = Cohorts.delete_cohort(inst_account, cohort)
    end
  end

  describe "Memberships" do
    test "add_student_to_cohort/2 creates a membership" do
      cohort = insert(:cohort)
      account = insert(:account)

      assert {:ok, %CohortMembership{} = membership} =
               Cohorts.add_student_to_cohort(cohort.id, account.id)

      assert membership.cohort_id == cohort.id
      assert membership.account_id == account.id
    end

    test "enforces unique membership constraint" do
      cohort = insert(:cohort)
      account = insert(:account)

      assert {:ok, _} = Cohorts.add_student_to_cohort(cohort.id, account.id)

      assert {:error, changeset} = Cohorts.add_student_to_cohort(cohort.id, account.id)
      assert "has already been taken" in errors_on(changeset).cohort_id
    end

    test "list_cohort_memberships/2 returns paginated and enriched memberships" do
      cohort = insert(:cohort)
      account = insert(:account, login: "student_john")

      Cohorts.add_student_to_cohort(cohort.id, account.id)

      {:ok, {memberships, meta}} = Cohorts.list_cohort_memberships(cohort.id, %{})

      assert meta.total_count == 1
      assert length(memberships) == 1

      membership = hd(memberships)
      assert membership.account.login == "student_john"
    end

    test "remove_student_from_cohort/1 deletes the membership" do
      cohort = insert(:cohort)
      account = insert(:account)
      {:ok, membership} = Cohorts.add_student_to_cohort(cohort.id, account.id)

      assert {:ok, _deleted} = Cohorts.remove_student_from_cohort(membership)

      assert_raise Ecto.NoResultsError, fn ->
        Cohorts.get_cohort_membership!(membership.id)
      end
    end
  end

  describe "get_cohort_options/1 (With ACL)" do
    test "returns a list of {name, id} tuples ordered by name for admin", %{admin: admin} do
      cohort2 = insert(:cohort, name: "Zeta Group", owner_id: admin.id)
      cohort1 = insert(:cohort, name: "Alpha Group", owner_id: admin.id)
      cohort3 = insert(:cohort, name: "Beta Group", owner_id: admin.id)

      options = Cohorts.get_cohort_options(admin)

      assert length(options) == 3
      assert Enum.at(options, 0) == {cohort1.name, cohort1.id}
      assert Enum.at(options, 1) == {cohort3.name, cohort3.id}
      assert Enum.at(options, 2) == {cohort2.name, cohort2.id}
    end

    test "respects own_only policy for instructors", %{
      inst1_account: inst1_account,
      inst1_profile: inst1_profile,
      inst2_account: inst2_account,
      inst2_profile: inst2_profile
    } do
      {:ok, my_cohort} =
        Cohorts.create_cohort(inst1_account, %{
          "name" => "My Cohort",
          "instructor_ids" => [inst1_profile.id]
        })

      {:ok, _other_cohort} =
        Cohorts.create_cohort(inst2_account, %{
          "name" => "Other Cohort",
          "instructor_ids" => [inst2_profile.id]
        })

      options = Cohorts.get_cohort_options(inst1_account)

      assert length(options) == 1
      assert hd(options) == {my_cohort.name, my_cohort.id}
    end

    test "returns empty list if user has no access" do
      role = insert(:role, permissions: [])
      user_no_access = insert(:account, role: role)

      insert(:cohort, name: "Hidden Cohort")

      options = Cohorts.get_cohort_options(user_no_access)

      assert options == []
    end
  end

  describe "add_student_to_cohort/2 — overlap prevention" do
    test "allows adding student when cohort has no course enrollments" do
      cohort = insert(:cohort)
      account = insert(:account)

      assert {:ok, %CohortMembership{}} = Cohorts.add_student_to_cohort(cohort.id, account.id)
    end

    test "allows adding student when they have no access to cohort's courses" do
      cohort = insert(:cohort)
      course = insert(:course, status: :published)
      account = insert(:account)

      insert(:enrollment, cohort: cohort, course_id: course.id, account_id: nil, status: :active)

      assert {:ok, %CohortMembership{}} = Cohorts.add_student_to_cohort(cohort.id, account.id)
    end

    test "REJECTS student already in another cohort enrolled on the same course" do
      course = insert(:course, title: "Elixir Mastery", status: :published)
      account = insert(:account)

      cohort_a = insert(:cohort)
      cohort_b = insert(:cohort)

      insert(:enrollment,
        cohort: cohort_a,
        course_id: course.id,
        account_id: nil,
        status: :active
      )

      insert(:enrollment,
        cohort: cohort_b,
        course_id: course.id,
        account_id: nil,
        status: :active
      )

      assert {:ok, _} = Cohorts.add_student_to_cohort(cohort_a.id, account.id)

      assert {:error, msg} = Cohorts.add_student_to_cohort(cohort_b.id, account.id)
      assert msg =~ "Cannot add student"
      assert msg =~ "Elixir Mastery"
      assert msg =~ "through other enrollment"
    end

    test "REJECTS student with individual enrollment on cohort's course" do
      course = insert(:course, title: "Phoenix Deep Dive", status: :published)
      account = insert(:account)
      cohort = insert(:cohort)

      insert(:enrollment,
        cohort: nil,
        course_id: course.id,
        account_id: account.id,
        status: :active
      )

      insert(:enrollment, cohort: cohort, course_id: course.id, account_id: nil, status: :active)

      assert {:error, msg} = Cohorts.add_student_to_cohort(cohort.id, account.id)
      assert msg =~ "Phoenix Deep Dive"
    end

    test "lists all conflicting courses in error message" do
      course1 = insert(:course, title: "Course Alpha", status: :published)
      course2 = insert(:course, title: "Course Beta", status: :published)
      account = insert(:account)

      cohort_a = insert(:cohort)
      cohort_b = insert(:cohort)

      insert(:enrollment,
        cohort: cohort_a,
        course_id: course1.id,
        account_id: nil,
        status: :active
      )

      insert(:enrollment,
        cohort: cohort_a,
        course_id: course2.id,
        account_id: nil,
        status: :active
      )

      insert(:enrollment,
        cohort: cohort_b,
        course_id: course1.id,
        account_id: nil,
        status: :active
      )

      insert(:enrollment,
        cohort: cohort_b,
        course_id: course2.id,
        account_id: nil,
        status: :active
      )

      assert {:ok, _} = Cohorts.add_student_to_cohort(cohort_a.id, account.id)

      assert {:error, msg} = Cohorts.add_student_to_cohort(cohort_b.id, account.id)
      assert msg =~ "Course Alpha"
      assert msg =~ "Course Beta"
    end

    test "IGNORES dropped enrollments when checking overlaps" do
      course = insert(:course, title: "Dropped Course", status: :published)
      account = insert(:account)

      cohort_a = insert(:cohort)
      cohort_b = insert(:cohort)

      insert(:enrollment,
        cohort: cohort_a,
        course_id: course.id,
        account_id: nil,
        status: :dropped
      )

      insert(:enrollment,
        cohort: nil,
        course_id: course.id,
        account_id: account.id,
        status: :dropped
      )

      insert(:enrollment,
        cohort: cohort_b,
        course_id: course.id,
        account_id: nil,
        status: :active
      )

      assert {:ok, %CohortMembership{}} = Cohorts.add_student_to_cohort(cohort_b.id, account.id)
    end

    test "allows re-adding student to the SAME cohort (no self-conflict)" do
      course = insert(:course, status: :published)
      account = insert(:account)
      cohort = insert(:cohort)

      insert(:enrollment, cohort: cohort, course_id: course.id, account_id: nil, status: :active)
      assert {:ok, _} = Cohorts.add_student_to_cohort(cohort.id, account.id)

      assert {:error, %Ecto.Changeset{}} = Cohorts.add_student_to_cohort(cohort.id, account.id)
    end

    test "does not affect students not in the conflicting course" do
      course_x = insert(:course, title: "Course X", status: :published)
      course_y = insert(:course, title: "Course Y", status: :published)

      account = insert(:account)
      cohort_a = insert(:cohort)
      cohort_b = insert(:cohort)

      insert(:enrollment,
        cohort: cohort_a,
        course_id: course_x.id,
        account_id: nil,
        status: :active
      )

      insert(:enrollment,
        cohort: cohort_b,
        course_id: course_y.id,
        account_id: nil,
        status: :active
      )

      assert {:ok, _} = Cohorts.add_student_to_cohort(cohort_a.id, account.id)

      assert {:ok, %CohortMembership{}} = Cohorts.add_student_to_cohort(cohort_b.id, account.id)
    end
  end
end
