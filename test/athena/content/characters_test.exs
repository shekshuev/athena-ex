defmodule Athena.Content.CharactersTest do
  use Athena.DataCase, async: true

  alias Athena.Content.{Characters, Character}
  import Athena.Factory

  setup do
    role =
      insert(:role,
        permissions: [
          "characters.create",
          "characters.read",
          "characters.update",
          "characters.delete"
        ],
        policies: %{
          "characters.read" => ["own_only"],
          "characters.update" => ["own_only"],
          "characters.delete" => ["own_only"]
        }
      )

    admin_role =
      insert(:role,
        permissions: [
          "admin",
          "characters.create",
          "characters.read",
          "characters.update",
          "characters.delete"
        ]
      )

    owner1 = insert(:account, role: role)
    owner2 = insert(:account, role: role)
    admin = insert(:account, role: admin_role)

    %{owner1: owner1, owner2: owner2, admin: admin}
  end

  describe "list_characters/2 (with ACL)" do
    test "only lists characters belonging to the current owner (own_only)", %{
      owner1: owner1,
      owner2: owner2
    } do
      insert(:character, owner_id: owner1.id)
      insert(:character, owner_id: owner1.id)
      insert(:character, owner_id: owner2.id)

      assert {:ok, {characters, meta}} = Characters.list_characters(owner1, %{})

      assert length(characters) == 2
      assert meta.total_count == 2
      assert Enum.all?(characters, fn c -> c.owner_id == owner1.id end)
    end

    test "admin sees all characters", %{admin: admin, owner1: owner1, owner2: owner2} do
      insert(:character, owner_id: owner1.id)
      insert(:character, owner_id: owner2.id)

      assert {:ok, {characters, meta}} = Characters.list_characters(admin, %{})
      assert length(characters) == 2
      assert meta.total_count == 2
    end
  end

  describe "get_character/2 (with ACL)" do
    test "cannot fetch another owner's character", %{owner1: owner1, owner2: owner2} do
      character = insert(:character, owner_id: owner2.id)

      assert {:error, :not_found} = Characters.get_character(owner1, character.id)
    end
  end

  describe "create_character/2" do
    test "creates a character owned by the current user", %{owner1: owner1} do
      assert {:ok, %Character{} = character} =
               Characters.create_character(owner1, %{"name" => "Ada"})

      assert character.owner_id == owner1.id
      assert character.name == "Ada"
    end
  end

  describe "update_character/3 and delete_character/2 (with ACL)" do
    test "owner can update their own character", %{owner1: owner1} do
      character = insert(:character, owner_id: owner1.id, name: "Old Name")

      assert {:ok, updated} =
               Characters.update_character(owner1, character, %{"name" => "New Name"})

      assert updated.name == "New Name"
    end

    test "another owner cannot update someone else's character", %{owner1: owner1, owner2: owner2} do
      character = insert(:character, owner_id: owner2.id)

      assert {:error, :forbidden} =
               Characters.update_character(owner1, character, %{"name" => "Hijacked"})
    end

    test "another owner cannot delete someone else's character", %{owner1: owner1, owner2: owner2} do
      character = insert(:character, owner_id: owner2.id)

      assert {:error, :forbidden} = Characters.delete_character(owner1, character)
    end

    test "owner can delete their own character", %{owner1: owner1} do
      character = insert(:character, owner_id: owner1.id)

      assert {:ok, _} = Characters.delete_character(owner1, character)
    end
  end
end
