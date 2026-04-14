defmodule Athena.Learning.InstructorsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Instructors
  alias Athena.Learning.Instructor
  import Athena.Factory

  setup do
    admin_role = insert(:role, permissions: ["admin", "instructors.read"])
    admin = insert(:account, role: admin_role)

    inst_role =
      insert(:role,
        permissions: ["instructors.read"],
        policies: %{"instructors.read" => ["own_only"]}
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

    test "applies own_only policy so instructor sees only their profile", %{
      instructor_account: account,
      other_account: other
    } do
      insert(:instructor, owner_id: account.id)
      insert(:instructor, owner_id: other.id)

      {:ok, {instructors, meta}} = Instructors.list_instructors(account, %{})

      assert length(instructors) == 1
      assert hd(instructors).owner_id == account.id
      assert meta.total_count == 1
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

  describe "search_instructors/2" do
    test "finds instructors by title" do
      insert(:instructor, title: "Elixir Wizard")
      insert(:instructor, title: "Ruby Guru")

      results = Instructors.search_instructors("Elixir")

      assert length(results) == 1
      assert hd(results).title == "Elixir Wizard"
    end

    test "finds instructors by associated account login across contexts" do
      account = insert(:account, login: "hidden_dragon")

      instructor = insert(:instructor, owner_id: account.id, title: "Martial Arts Coach")

      results = Instructors.search_instructors("hidden")

      assert length(results) == 1
      assert hd(results).id == instructor.id
      assert hd(results).account.login == "hidden_dragon"
    end

    test "returns unique results when both title and login match" do
      account = insert(:account, login: "elixir_fan")
      insert(:instructor, owner_id: account.id, title: "Elixir Instructor")

      results = Instructors.search_instructors("Elixir")

      assert length(results) == 1
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

    test "returns not_found if user tries to access another's profile", %{
      instructor_account: account,
      other_account: other
    } do
      instructor = insert(:instructor, owner_id: other.id)

      assert {:error, :not_found} = Instructors.get_instructor(account, instructor.id)
    end

    test "returns not_found error if instructor does not exist", %{admin: admin} do
      assert {:error, :not_found} = Instructors.get_instructor(admin, Ecto.UUID.generate())
    end
  end

  describe "create_instructor/1" do
    test "creates an instructor with valid attributes" do
      owner_id = Ecto.UUID.generate()
      attrs = %{"title" => "Lead Educator", "bio" => "Loves teaching.", "owner_id" => owner_id}

      assert {:ok, %Instructor{} = instructor} = Instructors.create_instructor(attrs)
      assert instructor.title == "Lead Educator"
      assert instructor.bio == "Loves teaching."
      assert instructor.owner_id == owner_id
    end

    test "returns error changeset with invalid attributes" do
      assert {:error, changeset} = Instructors.create_instructor(%{"title" => ""})
      assert "can't be blank" in errors_on(changeset).title
      assert "can't be blank" in errors_on(changeset).owner_id
    end
  end

  describe "update_instructor/2" do
    test "updates instructor attributes" do
      instructor = insert(:instructor, title: "Old Title")

      assert {:ok, updated} = Instructors.update_instructor(instructor, %{"title" => "New Title"})
      assert updated.title == "New Title"
    end
  end

  describe "delete_instructor/1" do
    test "deletes the instructor", %{admin: admin} do
      instructor = insert(:instructor)
      assert {:ok, _deleted} = Instructors.delete_instructor(instructor)

      assert {:error, :not_found} = Instructors.get_instructor(admin, instructor.id)
    end
  end
end
