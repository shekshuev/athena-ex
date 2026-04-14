defmodule Athena.Content.LibraryTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Library
  alias Athena.Content.LibraryBlock
  import Athena.Factory

  setup do
    role =
      insert(:role,
        permissions: ["library.read", "library.update", "library.delete"],
        policies: %{"library.read" => ["own_only"], "library.update" => ["own_only"]}
      )

    admin_role = insert(:role, permissions: ["admin", "library.read"])

    owner1 = insert(:account, role: role)
    owner2 = insert(:account, role: role)
    admin = insert(:account, role: admin_role)

    %{owner1: owner1, owner2: owner2, admin: admin}
  end

  describe "list_library_blocks/2 (With ACL)" do
    test "should list only blocks belonging to the specified owner (own_only)", %{
      owner1: owner1,
      owner2: owner2
    } do
      insert(:library_block, owner_id: owner1.id)
      insert(:library_block, owner_id: owner1.id)
      insert(:library_block, owner_id: owner2.id)

      assert {:ok, {blocks, meta}} = Library.list_library_blocks(owner1, %{})

      assert length(blocks) == 2
      assert meta.total_count == 2
      assert Enum.all?(blocks, fn b -> b.owner_id == owner1.id end)
    end

    test "should apply pagination parameters", %{owner1: owner1} do
      insert_list(3, :library_block, owner_id: owner1.id)

      assert {:ok, {blocks, meta}} =
               Library.list_library_blocks(owner1, %{"page" => 1, "page_size" => 2})

      assert length(blocks) == 2
      assert meta.total_count == 3
    end

    test "admin sees all blocks", %{admin: admin, owner1: owner1, owner2: owner2} do
      insert(:library_block, owner_id: owner1.id)
      insert(:library_block, owner_id: owner2.id)

      assert {:ok, {blocks, meta}} = Library.list_library_blocks(admin, %{})
      assert length(blocks) == 2
      assert meta.total_count == 2
    end
  end

  describe "get_library_block/1 (Without ACL - Internal)" do
    test "should return a single library block by ID" do
      block = insert(:library_block)

      assert {:ok, fetched} = Library.get_library_block(block.id)
      assert fetched.id == block.id
    end

    test "should return not_found error when block does not exist" do
      assert {:error, :not_found} = Library.get_library_block(Ecto.UUID.generate())
    end
  end

  describe "get_library_block/2 (With ACL - Studio)" do
    test "should return block if user owns it", %{owner1: owner1} do
      block = insert(:library_block, owner_id: owner1.id)

      assert {:ok, fetched} = Library.get_library_block(owner1, block.id)
      assert fetched.id == block.id
    end

    test "should return not_found if user does not own it (own_only policy applied)", %{
      owner1: owner1,
      owner2: owner2
    } do
      block = insert(:library_block, owner_id: owner2.id)

      assert {:error, :not_found} = Library.get_library_block(owner1, block.id)
    end

    test "should return block for admin regardless of owner", %{admin: admin, owner1: owner1} do
      block = insert(:library_block, owner_id: owner1.id)

      assert {:ok, fetched} = Library.get_library_block(admin, block.id)
      assert fetched.id == block.id
    end
  end

  describe "create_library_block/1" do
    test "should create a new library block with valid attributes" do
      owner_id = Ecto.UUID.generate()

      attrs = %{
        "title" => "Base Template",
        "type" => "text",
        "content" => %{"text" => "Template body"},
        "tags" => ["base", "template"],
        "owner_id" => owner_id
      }

      assert {:ok, %LibraryBlock{} = block} = Library.create_library_block(attrs)

      assert block.title == "Base Template"
      assert block.type == :text
      assert block.tags == ["base", "template"]
      assert block.owner_id == owner_id
    end

    test "should return error changeset when required attributes are missing" do
      attrs = %{"title" => ""}

      assert {:error, changeset} = Library.create_library_block(attrs)
      assert "can't be blank" in errors_on(changeset).title
      assert "can't be blank" in errors_on(changeset).owner_id
    end
  end

  describe "update_library_block/2" do
    test "should update existing library block" do
      block = insert(:library_block, title: "Old Title")

      attrs = %{"title" => "Updated Title", "tags" => ["new"]}

      assert {:ok, updated} = Library.update_library_block(block, attrs)
      assert updated.title == "Updated Title"
      assert updated.tags == ["new"]
    end

    test "should return error changeset when update data is invalid" do
      block = insert(:library_block)

      assert {:error, changeset} = Library.update_library_block(block, %{"title" => ""})
      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "delete_library_block/1" do
    test "should permanently delete library block from database" do
      block = insert(:library_block)

      assert {:ok, _} = Library.delete_library_block(block)
      assert Repo.get(LibraryBlock, block.id) == nil
    end
  end

  describe "generate_exam_questions/1" do
    setup do
      owner = Ecto.UUID.generate()

      insert(:library_block,
        type: :quiz_question,
        tags: ["elixir", "hard"],
        owner_id: owner,
        content: %{"body" => %{"text" => "Q1"}, "question_type" => "single"}
      )

      insert(:library_block,
        type: :quiz_question,
        tags: ["elixir", "easy"],
        owner_id: owner,
        content: %{"body" => %{"text" => "Q2"}, "question_type" => "single"}
      )

      insert(:library_block,
        type: :quiz_question,
        tags: ["js", "easy"],
        owner_id: owner,
        content: %{"body" => %{"text" => "Q3"}, "question_type" => "multiple"}
      )

      insert(:library_block,
        type: :quiz_question,
        tags: ["elixir", "theory"],
        owner_id: owner,
        content: %{"body" => %{"text" => "Q4"}, "question_type" => "single"}
      )

      insert(:library_block,
        type: :quiz_question,
        tags: ["python"],
        owner_id: owner,
        content: %{"body" => %{"text" => "Q5"}, "question_type" => "single"}
      )

      :ok
    end

    test "should fetch exact count using only mandatory tags" do
      params = %{
        "count" => 2,
        "mandatory_tags" => ["elixir"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert length(results) == 2
    end

    test "should fill remaining quota using include_tags if mandatory tags are insufficient" do
      params = %{
        "count" => 3,
        "mandatory_tags" => ["hard"],
        "include_tags" => ["elixir"],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert length(results) == 3
    end

    test "should strictly exclude blocks matching exclude_tags" do
      params = %{
        "count" => 5,
        "mandatory_tags" => [],
        "include_tags" => ["easy"],
        "exclude_tags" => ["js"]
      }

      results = Library.generate_exam_questions(params)

      assert length(results) == 1
      assert hd(results).question == %{"text" => "Q2"}
    end

    test "should correctly map original block content to the required snapshot format" do
      params = %{
        "count" => 1,
        "mandatory_tags" => ["python"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert length(results) == 1

      snapshot = hd(results)

      assert snapshot.id != nil
      assert snapshot.original_block_id != nil
      assert snapshot.type == "single"
      assert snapshot.question == %{"text" => "Q5"}

      assert Map.has_key?(snapshot, :options)
      assert Map.has_key?(snapshot, :correct_answer_text)
      assert Map.has_key?(snapshot, :explanation)
    end

    test "should handle gracefully when no blocks match the criteria" do
      params = %{
        "count" => 5,
        "mandatory_tags" => ["ruby"],
        "include_tags" => ["rust"],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert results == []
    end
  end
end
