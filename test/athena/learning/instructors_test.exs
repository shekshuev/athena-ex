defmodule Athena.Learning.InstructorsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Instructors
  alias Athena.Learning.Instructor
  import Athena.Factory

  setup do
    admin_role =
      insert(:role,
        permissions: ["admin", "instructors.read", "instructors.update", "instructors.delete"]
      )

    admin = insert(:account, role: admin_role)

    inst_role =
      insert(:role,
        permissions: [
          "instructors.read",
          "instructors.update",
          "instructors.delete"
        ],
        policies: %{
          "instructors.update" => ["own_only"],
          "instructors.delete" => ["own_only"]
        }
      )

    instructor_account = insert(:account, role: inst_role)
    other_account = insert(:account, role: inst_role)

    %{
      admin: admin,
      instructor_account: instructor_account,
      other_account: other_account
    }
  end

  describe "list_instructors/2 (With ACL)" do
    test "returns a paginated list of all instructors for admin", %{admin: admin} do
      insert_list(3, :instructor)

      {:ok, {instructors, meta}} = Instructors.list_instructors(admin, %{page: 1, page_size: 2})

      assert length(instructors) == 2
      assert meta.total_count >= 3
    end

    test "instructor sees all profiles if read policy has no own_only restriction", %{
      instructor_account: account,
      other_account: other
    } do
      insert(:instructor, owner_id: account.id)
      insert(:instructor, owner_id: other.id)

      {:ok, {instructors, meta}} = Instructors.list_instructors(account, %{})

      assert length(instructors) >= 2
      assert meta.total_count >= 2
    end

    test "enriches instructors with account data", %{admin: admin} do
      account = insert(:account, login: "test_prof")
      insert(:instructor, owner_id: account.id)

      {:ok, {instructors, _meta}} = Instructors.list_instructors(admin, %{})

      instructor = Enum.find(instructors, &(&1.owner_id == account.id))
      assert instructor.account != nil
      assert instructor.account.login == "test_prof"
    end
  end

  describe "search_instructors/3" do
    test "finds instructors by title", %{admin: admin} do
      insert(:instructor, title: "Elixir Wizard")
      insert(:instructor, title: "Ruby Guru")

      results = Instructors.search_instructors(admin, "Elixir")

      assert length(results) == 1
      assert hd(results).title == "Elixir Wizard"
    end

    test "finds instructors by associated account login across contexts", %{admin: admin} do
      account = insert(:account, login: "hidden_dragon")

      instructor = insert(:instructor, owner_id: account.id, title: "Martial Arts Coach")

      results = Instructors.search_instructors(admin, "hidden")

      assert length(results) == 1
      assert hd(results).id == instructor.id
      assert hd(results).account.login == "hidden_dragon"
    end

    test "returns unique results when both title and login match", %{admin: admin} do
      account = insert(:account, login: "elixir_fan")
      insert(:instructor, owner_id: account.id, title: "Elixir Instructor")

      results = Instructors.search_instructors(admin, "Elixir")

      assert length(results) == 1
    end

    test "returns empty list if user lacks read permission" do
      user_no_access = insert(:account, role: insert(:role, permissions: []))
      insert(:instructor, title: "Elixir Hacker")

      results = Instructors.search_instructors(user_no_access, "Elixir")
      assert results == []
    end
  end

  describe "get_instructor/2 (With ACL)" do
    test "returns the enriched instructor for admin", %{admin: admin} do
      account = insert(:account, login: "specific_user")
      instructor = insert(:instructor, owner_id: account.id)

      assert {:ok, fetched} = Instructors.get_instructor(admin, instructor.id)

      assert fetched.id == instructor.id
      assert fetched.account.login == "specific_user"
    end

    test "returns instructor if they own the profile", %{instructor_account: account} do
      instructor = insert(:instructor, owner_id: account.id)

      assert {:ok, fetched} = Instructors.get_instructor(account, instructor.id)
      assert fetched.id == instructor.id
    end

    test "returns instructor even if it belongs to someone else (global read)", %{
      instructor_account: account,
      other_account: other
    } do
      instructor = insert(:instructor, owner_id: other.id)

      assert {:ok, fetched} = Instructors.get_instructor(account, instructor.id)
      assert fetched.id == instructor.id
    end

    test "returns not_found if user lacks read permission" do
      user_no_access = insert(:account, role: insert(:role, permissions: []))
      instructor = insert(:instructor)

      assert {:error, :not_found} = Instructors.get_instructor(user_no_access, instructor.id)
    end

    test "returns not_found error if instructor does not exist", %{admin: admin} do
      assert {:error, :not_found} = Instructors.get_instructor(admin, Ecto.UUID.generate())
    end
  end

  describe "create_instructor/2" do
    test "creates an instructor with valid attributes", %{admin: admin} do
      owner_id = Ecto.UUID.generate()
      attrs = %{"title" => "Lead Educator", "bio" => "Loves teaching.", "owner_id" => owner_id}

      assert {:ok, %Instructor{} = instructor} = Instructors.create_instructor(admin, attrs)
      assert instructor.title == "Lead Educator"
      assert instructor.bio == "Loves teaching."
      assert instructor.owner_id == owner_id
    end

    test "returns error changeset with invalid attributes", %{admin: admin} do
      assert {:error, changeset} = Instructors.create_instructor(admin, %{"title" => ""})
      assert "can't be blank" in errors_on(changeset).title
      assert "can't be blank" in errors_on(changeset).owner_id
    end

    test "returns unauthorized if user lacks create permission" do
      user_no_access = insert(:account, role: insert(:role, permissions: []))
      attrs = %{"title" => "Hacker", "owner_id" => Ecto.UUID.generate()}

      assert {:error, :unauthorized} = Instructors.create_instructor(user_no_access, attrs)
    end
  end

  describe "update_instructor/3" do
    test "updates instructor attributes", %{admin: admin} do
      instructor = insert(:instructor, title: "Old Title")

      assert {:ok, updated} =
               Instructors.update_instructor(admin, instructor, %{"title" => "New Title"})

      assert updated.title == "New Title"
    end

    test "instructor can update their own profile (own_only policy)", %{
      instructor_account: account
    } do
      instructor = insert(:instructor, owner_id: account.id, title: "My Profile")

      assert {:ok, updated} =
               Instructors.update_instructor(account, instructor, %{"title" => "Updated"})

      assert updated.title == "Updated"
    end

    test "returns unauthorized if instructor tries to update someone else's profile", %{
      instructor_account: account,
      other_account: other
    } do
      other_instructor = insert(:instructor, owner_id: other.id)

      assert {:error, :unauthorized} =
               Instructors.update_instructor(account, other_instructor, %{"title" => "Hacked"})
    end
  end

  describe "delete_instructor/2" do
    test "deletes the instructor", %{admin: admin} do
      instructor = insert(:instructor)
      assert {:ok, _deleted} = Instructors.delete_instructor(admin, instructor)

      assert {:error, :not_found} = Instructors.get_instructor(admin, instructor.id)
    end

    test "returns unauthorized if instructor tries to delete someone else's profile", %{
      instructor_account: account,
      other_account: other
    } do
      other_instructor = insert(:instructor, owner_id: other.id)

      assert {:error, :unauthorized} = Instructors.delete_instructor(account, other_instructor)
    end
  end
end
