defmodule Athena.Content.LibraryTest do
  use Athena.DataCase, async: true

  alias Athena.Content.{Library, LibraryBlock, Block, TicketUsage}
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

    test "should filter only pinned blocks, if course_id passed and pinned_only = true", %{
      owner1: owner1
    } do
      course = insert(:course)
      pinned_block = insert(:library_block, owner_id: owner1.id)
      _other_block = insert(:library_block, owner_id: owner1.id)

      insert(:course_library_block, course: course, library_block: pinned_block)

      assert {:ok, {blocks, _meta}} =
               Library.list_library_blocks(owner1, %{
                 "course_id" => course.id,
                 "pinned_only" => "true"
               })

      assert length(blocks) == 1
      assert hd(blocks).id == pinned_block.id
    end

    test "should show blocks in course library, which doesn't belongs to user, if course_id passed",
         %{
           owner1: owner1,
           owner2: owner2
         } do
      course = insert(:course)

      secret_block = insert(:library_block, owner_id: owner2.id, is_public: false)

      insert(:course_library_block, course: course, library_block: secret_block)

      assert {:ok, {blocks, _meta}} =
               Library.list_library_blocks(owner1, %{"course_id" => course.id})

      assert Enum.any?(blocks, fn b -> b.id == secret_block.id end)
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

    test "should return unauthorized if user lacks permission", %{
      owner1: owner1,
      owner2: owner2
    } do
      block = insert(:library_block, owner_id: owner2.id)

      assert {:error, :unauthorized} = Library.delete_library_block(owner1, block)
      assert Repo.get(LibraryBlock, block.id) != nil
    end

    test "returns error changeset if block is pinned to a course workspace", %{owner1: owner1} do
      block = insert(:library_block, owner_id: owner1.id)
      course = insert(:course)

      insert(:course_library_block, course: course, library_block: block)

      assert {:error, changeset} = Library.delete_library_block(owner1, block)

      assert "is pinned to a course and cannot be deleted" in errors_on(changeset).course_library_blocks
    end
  end

  describe "generate_exam_questions/2" do
    setup do
      owner = Ecto.UUID.generate()
      course = insert(:course)

      b1 =
        insert(:library_block,
          type: :quiz_question,
          tags: ["elixir", "hard"],
          owner_id: owner,
          content: %{"body" => %{"text" => "Q1"}, "question_type" => "single"}
        )

      b2 =
        insert(:library_block,
          type: :quiz_question,
          tags: ["elixir", "easy"],
          owner_id: owner,
          content: %{"body" => %{"text" => "Q2"}, "question_type" => "single"}
        )

      b3 =
        insert(:library_block,
          type: :quiz_question,
          tags: ["js", "easy"],
          owner_id: owner,
          content: %{"body" => %{"text" => "Q3"}, "question_type" => "multiple"}
        )

      b4 =
        insert(:library_block,
          type: :quiz_question,
          tags: ["elixir", "theory"],
          owner_id: owner,
          content: %{"body" => %{"text" => "Q4"}, "question_type" => "single"}
        )

      b5 =
        insert(:library_block,
          type: :quiz_question,
          tags: ["python"],
          owner_id: owner,
          content: %{"body" => %{"text" => "Q5"}, "question_type" => "single"}
        )

      for b <- [b1, b2, b3, b4, b5] do
        insert(:course_library_block, course: course, library_block: b)
      end

      %{course: course, owner: owner}
    end

    test "should fetch exact count using only mandatory tags", %{course: course} do
      params = %{
        "count" => 2,
        "mandatory_tags" => ["elixir"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(course.id, params)
      assert length(results) == 2

      assert Enum.all?(results, fn b -> %Block{} = b end)
      assert Enum.all?(results, fn b -> b.type == :quiz_question end)
    end

    test "should fill remaining quota using include_tags if mandatory tags are insufficient", %{
      course: course
    } do
      params = %{
        "count" => 3,
        "mandatory_tags" => ["hard"],
        "include_tags" => ["elixir"],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(course.id, params)
      assert length(results) == 3
    end

    test "should strictly exclude blocks matching exclude_tags", %{course: course} do
      params = %{
        "count" => 5,
        "mandatory_tags" => [],
        "include_tags" => ["easy"],
        "exclude_tags" => ["js"]
      }

      results = Library.generate_exam_questions(course.id, params)

      assert length(results) == 1
      block = hd(results)
      assert block.type == :quiz_question

      assert block.content["body"] == %{"text" => "Q2"}
      assert block.content["question_type"] == "single"
    end

    test "should correctly map original block content to Block snapshot format", %{course: course} do
      params = %{
        "count" => 1,
        "mandatory_tags" => ["python"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(course.id, params)
      assert length(results) == 1

      snapshot = hd(results)

      assert %Block{} = snapshot
      assert snapshot.id != nil
      assert snapshot.type == :quiz_question
      assert snapshot.content["body"] == %{"text" => "Q5"}
      assert snapshot.content["question_type"] == "single"
    end

    test "should handle gracefully when no blocks match the criteria", %{course: course} do
      params = %{
        "count" => 5,
        "mandatory_tags" => ["ruby"],
        "include_tags" => ["rust"],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(course.id, params)
      assert results == []
    end

    test "should return empty list when passed non-map argument", %{course: course} do
      assert Library.generate_exam_questions(course.id, nil) == []
      assert Library.generate_exam_questions(course.id, "invalid") == []
      assert Library.generate_exam_questions(course.id, 42) == []
    end

    test "should use default count of 10 if not specified", %{course: course} do
      owner = Ecto.UUID.generate()

      blocks =
        insert_list(12, :library_block,
          type: :quiz_question,
          tags: ["bulk"],
          owner_id: owner,
          content: %{"body" => %{"text" => "bulk"}, "question_type" => "single"}
        )

      for b <- blocks do
        insert(:course_library_block, course: course, library_block: b)
      end

      params = %{
        "mandatory_tags" => ["bulk"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(course.id, params)
      assert length(results) == 10
    end

    test "should not duplicate mandatory blocks in random selection", %{course: course} do
      owner = Ecto.UUID.generate()

      b =
        insert(:library_block,
          type: :quiz_question,
          tags: ["unique_mandatory"],
          owner_id: owner,
          content: %{"body" => %{"text" => "mandatory"}, "question_type" => "single"}
        )

      insert(:course_library_block, course: course, library_block: b)

      params = %{
        "count" => 5,
        "mandatory_tags" => ["unique_mandatory"],
        "include_tags" => ["unique_mandatory"],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(course.id, params)
      assert length(results) == 1
    end

    test "should include code blocks in exam generation", %{course: course} do
      owner = Ecto.UUID.generate()

      b =
        insert(:library_block,
          type: :code,
          tags: ["python_code"],
          owner_id: owner,
          content: %{"language" => "python", "code" => "print('hello')"}
        )

      insert(:course_library_block, course: course, library_block: b)

      params = %{
        "count" => 1,
        "mandatory_tags" => ["python_code"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(course.id, params)
      assert length(results) == 1
      assert hd(results).type == :code
      assert hd(results).content["language"] == "python"
    end

    test "should include file_assignment blocks in exam generation", %{course: course} do
      owner = Ecto.UUID.generate()

      b =
        insert(:library_block,
          type: :file_assignment,
          tags: ["assignment"],
          owner_id: owner,
          content: %{"max_files" => 3}
        )

      insert(:course_library_block, course: course, library_block: b)

      params = %{
        "count" => 1,
        "mandatory_tags" => ["assignment"],
        "include_tags" => [],
        "exclude_tags" => []
      }

      results = Library.generate_exam_questions(course.id, params)
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

  describe "generate_ticket_questions/3" do
    setup do
      owner = Ecto.UUID.generate()
      course = insert(:course)

      q1 = insert(:library_block, type: :quiz_question, tags: ["db", "theory"], owner_id: owner)
      q2 = insert(:library_block, type: :quiz_question, tags: ["db", "theory"], owner_id: owner)
      q3 = insert(:library_block, type: :quiz_question, tags: ["db", "practice"], owner_id: owner)

      for q <- [q1, q2, q3] do
        insert(:course_library_block, course: course, library_block: q)
      end

      %{course: course, q1: q1, q2: q2, q3: q3}
    end

    test "fetches blocks matching slot tags and maps to Block structs", %{
      course: course,
      q1: q1,
      q2: q2,
      q3: q3
    } do
      slots = [
        %{"id" => "s1", "tags" => ["db", "theory"]},
        %{"id" => "s2", "tags" => ["db", "practice"]}
      ]

      usage = TicketUsage.new()
      results = Library.generate_ticket_questions(course.id, slots, usage)

      assert length(results) == 2
      assert Enum.all?(results, fn b -> %Block{} = b end)

      original_ids = Enum.map(results, & &1.content["original_block_id"])
      assert q3.id in original_ids
      assert q1.id in original_ids or q2.id in original_ids
    end

    test "prioritizes blocks with the lowest usage count", %{course: course, q1: q1, q2: q2} do
      slots = [%{"id" => "s1", "tags" => ["db", "theory"]}]

      usage = TicketUsage.new(%{q1.id => 10, q2.id => 0})
      results = Library.generate_ticket_questions(course.id, slots, usage)

      assert length(results) == 1
      assert hd(results).content["original_block_id"] == q2.id
    end

    test "does not pick the same block twice in one ticket (prevents dupes)", %{
      course: course,
      q1: q1,
      q2: q2
    } do
      slots = [
        %{"id" => "s1", "tags" => ["db", "theory"]},
        %{"id" => "s2", "tags" => ["db", "theory"]},
        %{"id" => "s3", "tags" => ["db", "theory"]}
      ]

      usage = TicketUsage.new()
      results = Library.generate_ticket_questions(course.id, slots, usage)

      assert length(results) == 2
      original_ids = Enum.map(results, & &1.content["original_block_id"])
      assert q1.id in original_ids
      assert q2.id in original_ids
    end

    test "skips slot gracefully if no candidates match", %{course: course} do
      slots = [%{"id" => "s1", "tags" => ["impossible", "tags"]}]
      usage = TicketUsage.new()

      results = Library.generate_ticket_questions(course.id, slots, usage)
      assert results == []
    end
  end
end
