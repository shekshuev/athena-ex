defmodule Athena.Content.LibraryTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Library
  alias Athena.Content.LibraryBlock
  import Athena.Factory

  describe "list_library_blocks/2" do
    test "should list only blocks belonging to the specified owner" do
      owner1 = Ecto.UUID.generate()
      owner2 = Ecto.UUID.generate()

      insert(:library_block, owner_id: owner1)
      insert(:library_block, owner_id: owner1)
      insert(:library_block, owner_id: owner2)

      assert {:ok, {blocks, meta}} = Library.list_library_blocks(%{}, owner1)

      assert length(blocks) == 2
      assert meta.total_count == 2
      assert Enum.all?(blocks, fn b -> b.owner_id == owner1 end)
    end

    test "should apply pagination parameters" do
      owner = Ecto.UUID.generate()
      insert_list(3, :library_block, owner_id: owner)

      assert {:ok, {blocks, meta}} =
               Library.list_library_blocks(%{"page" => 1, "page_size" => 2}, owner)

      assert length(blocks) == 2
      assert meta.total_count == 3
    end
  end

  describe "get_library_block/1" do
    test "should return a single library block by ID" do
      block = insert(:library_block)

      assert {:ok, fetched} = Library.get_library_block(block.id)
      assert fetched.id == block.id
    end

    test "should return not_found error when block does not exist" do
      assert {:error, :not_found} = Library.get_library_block(Ecto.UUID.generate())
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

      # Insert varying blocks to test the array intersection (&&) queries
      insert(:library_block,
        type: :quiz_question,
        tags: ["elixir", "hard"],
        owner_id: owner,
        content: %{"question" => "Q1", "type" => "single"}
      )

      insert(:library_block,
        type: :quiz_question,
        tags: ["elixir", "easy"],
        owner_id: owner,
        content: %{"question" => "Q2", "type" => "single"}
      )

      insert(:library_block,
        type: :quiz_question,
        tags: ["js", "easy"],
        owner_id: owner,
        content: %{"question" => "Q3", "type" => "multiple"}
      )

      insert(:library_block,
        type: :quiz_question,
        tags: ["elixir", "theory"],
        owner_id: owner,
        content: %{"question" => "Q4", "type" => "single"}
      )

      insert(:library_block,
        type: :quiz_question,
        tags: ["python"],
        owner_id: owner,
        content: %{"question" => "Q5", "type" => "single"}
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
        # Matches 1 block ("elixir", "hard")
        "mandatory_tags" => ["hard"],
        # Should fetch 2 more from the remaining Elixir blocks
        "include_tags" => ["elixir"],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert length(results) == 3
    end

    test "should strictly exclude blocks matching exclude_tags" do
      params = %{
        # High count to attempt fetching all available
        "count" => 5,
        "mandatory_tags" => [],
        # Matches 2 blocks ("elixir easy", "js easy")
        "include_tags" => ["easy"],
        # Should exclude "js easy"
        "exclude_tags" => ["js"]
      }

      results = Library.generate_exam_questions(params)

      # Since "js" is excluded, only "elixir easy" remains
      assert length(results) == 1
      assert hd(results).question == "Q2"
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

      # Verify mapping
      assert snapshot.id != nil
      assert snapshot.original_block_id != nil
      assert snapshot.type == "single"
      assert snapshot.question == "Q5"

      # Keys should be atoms according to the struct/map format generated in the logic
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
