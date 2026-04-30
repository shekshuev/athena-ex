defmodule Athena.Identity.ProfilesTest do
  use Athena.DataCase, async: true

  alias Athena.Identity.Profiles
  alias Athena.Identity.Profile
  import Athena.Factory

  describe "get_profile_by_owner/1" do
    test "should return profile, if exists" do
      profile = insert(:profile)
      assert {:ok, fetched} = Profiles.get_profile_by_owner(profile.owner_id)
      assert fetched.id == profile.id
    end

    test "should return error if profile doesn't exist" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Profiles.get_profile_by_owner(fake_id)
    end
  end

  describe "create_profile/2" do
    test "should create profile" do
      account = insert(:account)
      attrs = %{"first_name" => "Ivan", "last_name" => "Ivanov"}

      assert {:ok, %Profile{} = profile} = Profiles.create_profile(account.id, attrs)
      assert profile.first_name == "Ivan"
      assert profile.owner_id == account.id
    end

    test "should return error on duplicate profile" do
      account = insert(:account)
      insert(:profile, owner: account)

      attrs = %{"first_name" => "Ivan", "last_name" => "Ivanov"}

      assert {:error, changeset} = Profiles.create_profile(account.id, attrs)
      assert "has already been taken" in errors_on(changeset).owner_id
    end
  end

  describe "update_profile/3 (ACL & Self-Service)" do
    setup do
      admin_role = insert(:role, permissions: ["users.update"])
      admin = insert(:account, role: admin_role)

      student = insert(:account, role: insert(:role, permissions: []))
      other_student = insert(:account, role: insert(:role, permissions: []))

      %{admin: admin, student: student, other_student: other_student}
    end

    test "should update profile if the user is the owner (self-service)", %{student: student} do
      profile = insert(:profile, owner: student, first_name: "OldName")
      attrs = %{"first_name" => "NewName"}

      assert {:ok, updated} = Profiles.update_profile(student, profile, attrs)
      assert updated.first_name == "NewName"
    end

    test "should update profile if user is admin with users.update permission", %{
      admin: admin,
      student: student
    } do
      profile = insert(:profile, owner: student, first_name: "OldName")
      attrs = %{"first_name" => "AdminChanged"}

      assert {:ok, updated} = Profiles.update_profile(admin, profile, attrs)
      assert updated.first_name == "AdminChanged"
    end

    test "should return unauthorized if a user tries to update another user's profile without permission",
         %{
           student: student,
           other_student: other_student
         } do
      profile = insert(:profile, owner: student, first_name: "OldName")
      attrs = %{"first_name" => "Hacked"}

      assert {:error, :unauthorized} = Profiles.update_profile(other_student, profile, attrs)
    end
  end
end
