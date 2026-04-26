defmodule Athena.Learning.CohortsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Cohorts
  alias Athena.Learning.Cohort
  alias Athena.Learning.CohortMembership
  import Athena.Factory

  setup do
    admin_role = insert(:role, permissions: ["admin", "cohorts.read"])
    admin = insert(:account, role: admin_role)

    inst_role =
      insert(:role, permissions: ["cohorts.read"], policies: %{"cohorts.read" => ["own_only"]})

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
      inst2_profile: inst2_profile
    } do
      {:ok, my_cohort} =
        Cohorts.create_cohort(%{"name" => "My Cohort", "instructor_ids" => [inst1_profile.id]})

      {:ok, _other_cohort} =
        Cohorts.create_cohort(%{"name" => "Other Cohort", "instructor_ids" => [inst2_profile.id]})

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
      Cohorts.create_cohort(%{"name" => "Bootcamp", "instructor_ids" => [profile.id]})

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
        Cohorts.create_cohort(%{"name" => "Elixir 101", "instructor_ids" => [profile.id]})

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
        Cohorts.create_cohort(%{"name" => "My Group", "instructor_ids" => [profile.id]})

      assert {:ok, fetched_cohort} = Cohorts.get_cohort(account, cohort.id)
      assert fetched_cohort.id == cohort.id
    end

    test "returns not_found if instructor is not assigned to it (own_only)", %{
      inst1_account: account,
      inst2_profile: other_profile
    } do
      {:ok, cohort} =
        Cohorts.create_cohort(%{"name" => "Other Group", "instructor_ids" => [other_profile.id]})

      assert {:error, :not_found} = Cohorts.get_cohort(account, cohort.id)
    end

    test "returns not_found if cohort does not exist", %{admin: admin} do
      assert {:error, :not_found} = Cohorts.get_cohort(admin, Ecto.UUID.generate())
    end
  end

  describe "create_cohort/1" do
    test "creates a cohort with valid attributes" do
      attrs = %{"name" => "Winter Bootcamp", "description" => "Intensive course"}

      assert {:ok, %Cohort{} = cohort} = Cohorts.create_cohort(attrs)
      assert cohort.name == "Winter Bootcamp"
      assert cohort.description == "Intensive course"
    end

    test "creates a cohort and assigns instructors" do
      inst1 = insert(:instructor)
      inst2 = insert(:instructor)

      attrs = %{
        "name" => "Advanced Elixir",
        "instructor_ids" => [inst1.id, inst2.id]
      }

      assert {:ok, %Cohort{} = cohort} = Cohorts.create_cohort(attrs)
      assert cohort.name == "Advanced Elixir"
      assert length(cohort.instructors) == 2
    end

    test "returns error changeset with invalid attributes" do
      assert {:error, changeset} = Cohorts.create_cohort(%{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "update_cohort/2" do
    test "updates cohort attributes" do
      cohort = insert(:cohort, name: "Old Name")

      assert {:ok, updated} = Cohorts.update_cohort(cohort, %{"name" => "New Name"})
      assert updated.name == "New Name"
    end

    test "replaces assigned instructors" do
      inst1 = insert(:instructor)
      inst2 = insert(:instructor)

      {:ok, cohort} = Cohorts.create_cohort(%{"name" => "Base", "instructor_ids" => [inst1.id]})

      assert {:ok, updated} = Cohorts.update_cohort(cohort, %{"instructor_ids" => [inst2.id]})
      assert length(updated.instructors) == 1
      assert hd(updated.instructors).id == inst2.id
    end
  end

  describe "delete_cohort/1" do
    test "deletes the cohort", %{admin: admin} do
      cohort = insert(:cohort)
      assert {:ok, _deleted} = Cohorts.delete_cohort(cohort)

      assert {:error, :not_found} = Cohorts.get_cohort(admin, cohort.id)
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
      cohort2 = insert(:cohort, name: "Zeta Group")
      cohort1 = insert(:cohort, name: "Alpha Group")
      cohort3 = insert(:cohort, name: "Beta Group")

      options = Cohorts.get_cohort_options(admin)

      assert length(options) == 3
      assert Enum.at(options, 0) == {cohort1.name, cohort1.id}
      assert Enum.at(options, 1) == {cohort3.name, cohort3.id}
      assert Enum.at(options, 2) == {cohort2.name, cohort2.id}
    end

    test "respects own_only policy for instructors", %{
      inst1_account: inst1_account,
      inst1_profile: inst1_profile,
      inst2_profile: inst2_profile
    } do
      {:ok, my_cohort} =
        Cohorts.create_cohort(%{"name" => "My Cohort", "instructor_ids" => [inst1_profile.id]})

      {:ok, _other_cohort} =
        Cohorts.create_cohort(%{"name" => "Other Cohort", "instructor_ids" => [inst2_profile.id]})

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
end
