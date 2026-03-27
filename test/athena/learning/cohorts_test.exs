defmodule Athena.Learning.CohortsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Cohorts
  alias Athena.Learning.Cohort
  alias Athena.Learning.CohortMembership
  import Athena.Factory

  describe "list_cohorts/1" do
    test "returns a paginated list of cohorts" do
      insert_list(3, :cohort)

      {:ok, {cohorts, meta}} = Cohorts.list_cohorts(%{page: 1, page_size: 2})

      assert length(cohorts) == 2
      assert meta.total_count == 3
    end

    test "preloads and enriches instructors" do
      cohort = insert(:cohort)

      account = insert(:account, login: "test_instructor")
      instructor = insert(:instructor, owner_id: account.id)

      Cohorts.update_cohort(cohort, %{"instructor_ids" => [instructor.id]})

      {:ok, {fetched_cohorts, _meta}} = Cohorts.list_cohorts(%{})

      fetched_cohort = hd(fetched_cohorts)
      assert length(fetched_cohort.instructors) == 1
      fetched_instructor = hd(fetched_cohort.instructors)

      assert fetched_instructor.id == instructor.id
      assert fetched_instructor.account.login == "test_instructor"
    end
  end

  describe "get_cohort!/1" do
    test "returns the cohort with enriched instructors if it exists" do
      cohort = insert(:cohort)

      account = insert(:account, login: "master_yoda")
      instructor = insert(:instructor, owner_id: account.id)
      Cohorts.update_cohort(cohort, %{"instructor_ids" => [instructor.id]})

      fetched_cohort = Cohorts.get_cohort!(cohort.id)
      assert fetched_cohort.id == cohort.id

      fetched_instructor = hd(fetched_cohort.instructors)
      assert fetched_instructor.account.login == "master_yoda"
    end

    test "raises error if cohort does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Cohorts.get_cohort!(Ecto.UUID.generate())
      end
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
    test "deletes the cohort" do
      cohort = insert(:cohort)
      assert {:ok, _deleted} = Cohorts.delete_cohort(cohort)

      assert_raise Ecto.NoResultsError, fn ->
        Cohorts.get_cohort!(cohort.id)
      end
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
end
