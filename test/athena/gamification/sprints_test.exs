defmodule Athena.Gamification.SprintsTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.{Sprints, Sprint}
  alias Athena.Learning.Cohorts
  import Athena.Factory

  defp active_window do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {DateTime.add(now, -3600, :second), DateTime.add(now, 3600, :second)}
  end

  setup do
    owner_role = insert(:role, permissions: ["cohorts.update", "cohorts.read"])
    owner = insert(:account, role: owner_role)
    cohort = insert(:cohort, owner_id: owner.id)

    outsider_role = insert(:role, permissions: [])
    outsider = insert(:account, role: outsider_role)

    %{owner: owner, cohort: cohort, outsider: outsider}
  end

  describe "create_sprint/2" do
    test "creates a sprint for a cohort the user manages", %{owner: owner, cohort: cohort} do
      {starts_at, ends_at} = active_window()

      assert {:ok, %Sprint{} = sprint} =
               Sprints.create_sprint(owner, %{
                 "cohort_id" => cohort.id,
                 "title" => "Exam push",
                 "starts_at" => starts_at,
                 "ends_at" => ends_at,
                 "xp_multiplier" => "2"
               })

      assert sprint.created_by == owner.id
    end

    test "is forbidden for a user who doesn't manage the cohort", %{
      outsider: outsider,
      cohort: cohort
    } do
      {starts_at, ends_at} = active_window()

      assert {:error, :forbidden} =
               Sprints.create_sprint(outsider, %{
                 "cohort_id" => cohort.id,
                 "title" => "Nope",
                 "starts_at" => starts_at,
                 "ends_at" => ends_at,
                 "xp_multiplier" => "2"
               })
    end

    test "rejects a multiplier outside the fixed pick-list", %{owner: owner, cohort: cohort} do
      {starts_at, ends_at} = active_window()

      assert {:error, changeset} =
               Sprints.create_sprint(owner, %{
                 "cohort_id" => cohort.id,
                 "title" => "Cheeky",
                 "starts_at" => starts_at,
                 "ends_at" => ends_at,
                 "xp_multiplier" => "10"
               })

      refute changeset.valid?
    end

    test "rejects an end time before the start time", %{owner: owner, cohort: cohort} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:error, changeset} =
               Sprints.create_sprint(owner, %{
                 "cohort_id" => cohort.id,
                 "title" => "Backwards",
                 "starts_at" => now,
                 "ends_at" => DateTime.add(now, -3600, :second),
                 "xp_multiplier" => "1.5"
               })

      refute changeset.valid?
    end
  end

  describe "active_multiplier_for_account/1" do
    test "returns the multiplier of a currently running sprint for the account's cohort", %{
      owner: owner,
      cohort: cohort
    } do
      student = insert(:account)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      {starts_at, ends_at} = active_window()

      Sprints.create_sprint(owner, %{
        "cohort_id" => cohort.id,
        "title" => "Push",
        "starts_at" => starts_at,
        "ends_at" => ends_at,
        "xp_multiplier" => "2"
      })

      assert Decimal.equal?(Sprints.active_multiplier_for_account(student.id), Decimal.new("2"))
    end

    test "returns nil with no active sprint" do
      student = insert(:account)
      assert Sprints.active_multiplier_for_account(student.id) == nil
    end

    test "ignores a sprint outside its time window", %{owner: owner, cohort: cohort} do
      student = insert(:account)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Sprints.create_sprint(owner, %{
        "cohort_id" => cohort.id,
        "title" => "Future",
        "starts_at" => DateTime.add(now, 3600, :second),
        "ends_at" => DateTime.add(now, 7200, :second),
        "xp_multiplier" => "2"
      })

      assert Sprints.active_multiplier_for_account(student.id) == nil
    end

    test "ignores an inactive sprint", %{owner: owner, cohort: cohort} do
      student = insert(:account)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      {starts_at, ends_at} = active_window()

      {:ok, sprint} =
        Sprints.create_sprint(owner, %{
          "cohort_id" => cohort.id,
          "title" => "Disabled",
          "starts_at" => starts_at,
          "ends_at" => ends_at,
          "xp_multiplier" => "2"
        })

      Sprints.update_sprint(owner, sprint, %{"is_active" => false})

      assert Sprints.active_multiplier_for_account(student.id) == nil
    end

    test "picks the highest multiplier when multiple sprints overlap", %{
      owner: owner,
      cohort: cohort
    } do
      student = insert(:account)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      {starts_at, ends_at} = active_window()

      Sprints.create_sprint(owner, %{
        "cohort_id" => cohort.id,
        "title" => "Small boost",
        "starts_at" => starts_at,
        "ends_at" => ends_at,
        "xp_multiplier" => "1.5"
      })

      Sprints.create_sprint(owner, %{
        "cohort_id" => cohort.id,
        "title" => "Big boost",
        "starts_at" => starts_at,
        "ends_at" => ends_at,
        "xp_multiplier" => "3"
      })

      assert Decimal.equal?(Sprints.active_multiplier_for_account(student.id), Decimal.new("3"))
    end
  end

  describe "update_sprint/3 and delete_sprint/2" do
    test "forbidden for a non-manager", %{outsider: outsider, owner: owner, cohort: cohort} do
      {starts_at, ends_at} = active_window()

      {:ok, sprint} =
        Sprints.create_sprint(owner, %{
          "cohort_id" => cohort.id,
          "title" => "T",
          "starts_at" => starts_at,
          "ends_at" => ends_at,
          "xp_multiplier" => "2"
        })

      assert {:error, :forbidden} =
               Sprints.update_sprint(outsider, sprint, %{"title" => "Hijack"})

      assert {:error, :forbidden} = Sprints.delete_sprint(outsider, sprint)
    end
  end

  # Sanity check that our test setup's ACL actually grants management —
  # exercised indirectly above, but pinned here for clarity/documentation.
  test "the seeded owner role can manage its own cohort", %{owner: owner, cohort: cohort} do
    assert Cohorts.can_manage_cohort_processes?(owner, cohort)
  end
end
