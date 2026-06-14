defmodule Athena.Content.LibraryTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Library
  alias Athena.Content.LibraryBlock
  alias Athena.Content.Block
  import Athena.Factory

  setup do
    role =
      insert(:role,
        permissions: ["library.read", "library.update", "library.delete"],
        policies: %{
          "library.read" => ["own_only"],
          "library.update" => ["own_only"],
          "library.delete" => ["own_only"]
        }
      )

    admin_role =
      insert(:role, permissions: ["admin", "library.read", "library.update", "library.delete"])

    student_role = insert(:role, permissions: [])

    owner1 = insert(:account, role: role)
    owner2 = insert(:account, role: role)
    admin = insert(:account, role: admin_role)
    student = insert(:account, role: student_role)

    %{owner1: owner1, owner2: owner2, admin: admin, student: student}
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

  describe "create_library_block/2 (With ACL)" do
    test "should create a new library block and auto-assign owner", %{owner1: owner1} do
      attrs = %{
        "title" => "Base Template",
        "type" => "text",
        "content" => %{"text" => "Template body"},
        "tags" => ["base", "template"]
      }

      assert {:ok, %LibraryBlock{} = block} = Library.create_library_block(owner1, attrs)

      assert block.title == "Base Template"
      assert block.type == :text
      assert block.tags == ["base", "template"]
      assert block.owner_id == owner1.id
    end

    test "should return error changeset when required attributes are missing", %{owner1: owner1} do
      attrs = %{"title" => ""}

      assert {:error, changeset} = Library.create_library_block(owner1, attrs)
      assert "can't be blank" in errors_on(changeset).title
    end

    test "should return unauthorized if user lacks permission", %{student: student} do
      assert {:error, :unauthorized} = Library.create_library_block(student, %{"title" => "Hack"})
    end
  end

  describe "update_library_block/3 (With ACL)" do
    test "should update existing library block if owner", %{owner1: owner1} do
      block = insert(:library_block, title: "Old Title", owner_id: owner1.id)
      attrs = %{"title" => "Updated Title", "tags" => ["new"]}

      assert {:ok, updated} = Library.update_library_block(owner1, block, attrs)
      assert updated.title == "Updated Title"
      assert updated.tags == ["new"]
    end

    test "should return error changeset when update data is invalid", %{owner1: owner1} do
      block = insert(:library_block, owner_id: owner1.id)

      assert {:error, changeset} = Library.update_library_block(owner1, block, %{"title" => ""})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "should return unauthorized if user tries to update another user's block", %{
      owner1: owner1,
      owner2: owner2
    } do
      block = insert(:library_block, owner_id: owner2.id)

      assert {:error, :unauthorized} =
               Library.update_library_block(owner1, block, %{"title" => "Hacked"})
    end
  end

  describe "delete_library_block/2 (With ACL)" do
    test "should permanently delete library block from database if owner", %{owner1: owner1} do
      block = insert(:library_block, owner_id: owner1.id)

      assert {:ok, _} = Library.delete_library_block(owner1, block)
      assert Repo.get(LibraryBlock, block.id) == nil
    end

    test "should return unauthorized if user tries to delete another user's block", %{
      owner1: owner1,
      owner2: owner2
    } do
      block = insert(:library_block, owner_id: owner2.id)

      assert {:error, :unauthorized} = Library.delete_library_block(owner1, block)
      assert Repo.get(LibraryBlock, block.id) != nil
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

      assert Enum.all?(results, fn b -> %Block{} = b end)
      assert Enum.all?(results, fn b -> b.type == :quiz_question end)
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
      block = hd(results)
      assert block.type == :quiz_question

      assert block.content["body"] == %{"text" => "Q2"}
      assert block.content["question_type"] == "single"
    end

    test "should correctly map original block content to Block snapshot format" do
      params = %{
        "count" => 1,
        "mandatory_tags" => ["python"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert length(results) == 1

      snapshot = hd(results)

      assert %Block{} = snapshot
      assert snapshot.id != nil
      assert snapshot.type == :quiz_question
      assert snapshot.content["body"] == %{"text" => "Q5"}
      assert snapshot.content["question_type"] == "single"

      assert snapshot.inserted_at != nil
      assert snapshot.updated_at != nil
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

    test "should return empty list when passed non-map argument" do
      assert Library.generate_exam_questions(nil) == []
      assert Library.generate_exam_questions("invalid") == []
      assert Library.generate_exam_questions(42) == []
    end

    test "should use default count of 10 if not specified" do
      owner = Ecto.UUID.generate()

      insert_list(12, :library_block,
        type: :quiz_question,
        tags: ["bulk"],
        owner_id: owner,
        content: %{"body" => %{"text" => "bulk"}, "question_type" => "single"}
      )

      params = %{
        "mandatory_tags" => ["bulk"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert length(results) == 10
    end

    test "should not duplicate mandatory blocks in random selection" do
      owner = Ecto.UUID.generate()

      insert(:library_block,
        type: :quiz_question,
        tags: ["unique_mandatory"],
        owner_id: owner,
        content: %{"body" => %{"text" => "mandatory"}, "question_type" => "single"}
      )

      params = %{
        "count" => 5,
        "mandatory_tags" => ["unique_mandatory"],
        "include_tags" => ["unique_mandatory"],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)

      assert length(results) == 1
    end

    test "should include code blocks in exam generation" do
      owner = Ecto.UUID.generate()

      insert(:library_block,
        type: :code,
        tags: ["python_code"],
        owner_id: owner,
        content: %{"language" => "python", "code" => "print('hello')"}
      )

      params = %{
        "count" => 1,
        "mandatory_tags" => ["python_code"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert length(results) == 1
      assert hd(results).type == :code
      assert hd(results).content["language"] == "python"
    end

    test "should include file_assignment blocks in exam generation" do
      owner = Ecto.UUID.generate()

      insert(:library_block,
        type: :file_assignment,
        tags: ["assignment"],
        owner_id: owner,
        content: %{"max_files" => 3}
      )

      params = %{
        "count" => 1,
        "mandatory_tags" => ["assignment"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(params)
      assert length(results) == 1
      assert hd(results).type == :file_assignment
    end
  end

  describe "Sharing and Roles Logic" do
    setup %{owner1: owner, owner2: collaborator} do
      block = insert(:library_block, owner_id: owner.id)
      %{block: block, owner: owner, collaborator: collaborator}
    end

    test "share_block creates a share and upserts role", %{
      owner: owner,
      block: block,
      collaborator: collaborator
    } do
      assert {:ok, share} = Library.share_block(owner, block, collaborator.id, :reader)
      assert share.role == :reader

      assert {:ok, updated_share} = Library.share_block(owner, block, collaborator.id, :writer)
      assert updated_share.role == :writer

      shares = Library.list_block_shares(block)
      assert length(shares) == 1
      assert hd(shares).account_id == collaborator.id
      assert hd(shares).role == :writer
    end

    test "update_library_block respects reader and writer roles", %{
      owner: owner,
      block: block,
      collaborator: collaborator
    } do
      Library.share_block(owner, block, collaborator.id, :reader)

      assert {:error, :unauthorized} =
               Library.update_library_block(collaborator, block, %{"title" => "Hacked"})

      Library.share_block(owner, block, collaborator.id, :writer)

      assert {:ok, updated} =
               Library.update_library_block(collaborator, block, %{"title" => "Collab Edit"})

      assert updated.title == "Collab Edit"
    end

    test "revoke_block_share removes access completely", %{
      owner: owner,
      block: block,
      collaborator: collaborator
    } do
      Library.share_block(owner, block, collaborator.id, :reader)
      assert {:ok, :revoked} = Library.revoke_block_share(owner, block, collaborator.id)
      assert Library.list_block_shares(block) == []
    end

    test "toggle_block_public changes visibility", %{owner: owner, block: block} do
      assert {:ok, updated} = Library.toggle_block_public(owner, block, true)
      assert updated.is_public == true

      assert {:ok, updated2} = Library.toggle_block_public(owner, block, false)
      assert updated2.is_public == false
    end

    test "toggle_block_public returns unauthorized for non-owner", %{
      block: block,
      collaborator: collaborator
    } do
      assert {:error, :unauthorized} = Library.toggle_block_public(collaborator, block, true)
    end

    test "toggle_block_public works for writer role", %{
      owner: owner,
      block: block,
      collaborator: collaborator
    } do
      Library.share_block(owner, block, collaborator.id, :writer)
      assert {:ok, updated} = Library.toggle_block_public(collaborator, block, true)
      assert updated.is_public == true
    end

    test "list_library_blocks scope includes shared and public blocks for non-owners", %{
      owner: owner,
      block: block,
      collaborator: collaborator
    } do
      public_block = insert(:library_block, owner_id: owner.id, is_public: true)

      Library.share_block(owner, block, collaborator.id, :reader)

      {:ok, {fetched_blocks, _}} = Library.list_library_blocks(collaborator, %{})
      ids = Enum.map(fetched_blocks, & &1.id)

      assert block.id in ids
      assert public_block.id in ids
    end

    test "can_edit_block? returns true for owner", %{owner: owner, block: block} do
      assert Library.can_edit_block?(owner, block) == true
    end

    test "can_edit_block? returns true for writer", %{
      owner: owner,
      block: block,
      collaborator: collaborator
    } do
      Library.share_block(owner, block, collaborator.id, :writer)
      assert Library.can_edit_block?(collaborator, block) == true
    end

    test "can_edit_block? returns false for reader", %{
      owner: owner,
      block: block,
      collaborator: collaborator
    } do
      Library.share_block(owner, block, collaborator.id, :reader)
      assert Library.can_edit_block?(collaborator, block) == false
    end

    test "can_edit_block? returns false for unrelated user", %{
      block: block,
      collaborator: collaborator
    } do
      assert Library.can_edit_block?(collaborator, block) == false
    end

    test "revoke_block_share returns unauthorized for non-owner non-writer", %{
      block: block,
      collaborator: collaborator
    } do
      assert {:error, :unauthorized} =
               Library.revoke_block_share(collaborator, block, collaborator.id)
    end

    test "share_block returns unauthorized for non-owner non-writer", %{
      block: block,
      collaborator: collaborator
    } do
      third_party = insert(:account)

      assert {:error, :unauthorized} =
               Library.share_block(collaborator, block, third_party.id, :reader)
    end
  end
end
