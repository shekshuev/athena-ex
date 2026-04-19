defmodule Athena.Content.BlocksTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Blocks
  alias Athena.Content.Block
  import Athena.Factory

  setup do
    %{section: insert(:section)}
  end

  describe "list_blocks_by_section/1" do
    test "should return block list order by order field", %{section: s} do
      b2 = insert(:block, section: s, order: 2000)
      b1 = insert(:block, section: s, order: 1000)
      b3 = insert(:block, section: s, order: 3000)

      blocks = Blocks.list_blocks_by_section(s.id)

      assert length(blocks) == 3
      assert Enum.at(blocks, 0).id == b1.id
      assert Enum.at(blocks, 1).id == b2.id
      assert Enum.at(blocks, 2).id == b3.id
    end

    test "should return empty block list", %{section: s} do
      assert Blocks.list_blocks_by_section(s.id) == []
    end

    test "should filter blocks based on user policies", %{section: s} do
      b_public = insert(:block, section: s, visibility: :enrolled, order: 1000)
      _b_hidden = insert(:block, section: s, visibility: :hidden, order: 2000)

      assert length(Blocks.list_blocks_by_section(s.id, :all)) == 2

      admin_role = insert(:role, permissions: ["admin"])
      admin = insert(:account, role: admin_role)
      filtered_for_admin = Blocks.list_blocks_by_section(s.id, admin)
      assert length(filtered_for_admin) == 1
      assert hd(filtered_for_admin).id == b_public.id

      user_role = insert(:role, permissions: [])
      user = insert(:account, role: user_role)

      filtered_blocks = Blocks.list_blocks_by_section(s.id, user)
      assert length(filtered_blocks) == 1
      assert hd(filtered_blocks).id == b_public.id
    end
  end

  describe "get_block/1" do
    test "should return block by its ID" do
      block = insert(:block)
      assert {:ok, fetched} = Blocks.get_block(block.id)
      assert fetched.id == block.id
    end

    test "should return error if block not found" do
      assert {:error, :not_found} = Blocks.get_block(Ecto.UUID.generate())
    end
  end

  describe "create_block/1" do
    test "should create block with order 1024", %{section: s} do
      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Hello World"},
        "section_id" => s.id
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(attrs)
      assert block.type == :text
      assert block.order == 1024
      assert block.section_id == s.id
      assert block.content == %{"text" => "Hello World"}
    end

    test "should evaluate order if other blocks exists", %{
      section: s
    } do
      insert(:block, section: s, order: 2048)

      attrs = %{
        "type" => "code",
        "content" => %{"code" => "IO.puts(:ok)"},
        "section_id" => s.id
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(attrs)
      assert block.order == 3072
    end

    test "should use order value from params", %{section: s} do
      insert(:block, section: s, order: 1000)

      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Injected"},
        "section_id" => s.id,
        "order" => 500
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(attrs)
      assert block.order == 500
    end

    test "should insert block between two existing blocks using after_id", %{section: s} do
      b1 = insert(:block, section: s, order: 1000)
      _b2 = insert(:block, section: s, order: 2000)

      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Inserted"},
        "section_id" => s.id,
        "after_id" => b1.id
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(attrs)
      assert block.order == 1500
    end

    test "should insert block at the end if after_id is the last block", %{section: s} do
      _b1 = insert(:block, section: s, order: 1000)
      b2 = insert(:block, section: s, order: 2000)

      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Inserted at end"},
        "section_id" => s.id,
        "after_id" => b2.id
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(attrs)
      assert block.order == 3024
    end

    test "should fallback to normal insertion at the end if after_id does not exist", %{
      section: s
    } do
      insert(:block, section: s, order: 1000)

      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Inserted"},
        "section_id" => s.id,
        "after_id" => Ecto.UUID.generate()
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(attrs)
      assert block.order == 2024
    end

    test "should return error on invalid params" do
      attrs = %{"type" => "text"}

      assert {:error, changeset} = Blocks.create_block(attrs)
      assert "can't be blank" in errors_on(changeset).section_id
    end
  end

  describe "update_block/2" do
    test "should update block" do
      block = insert(:block, type: :text, content: %{"text" => "Old text"})

      attrs = %{
        "content" => %{"text" => "New text"}
      }

      assert {:ok, updated} = Blocks.update_block(block, attrs)
      assert updated.content == %{"text" => "New text"}
    end

    test "should return error on invalid params" do
      block = insert(:block)

      assert {:error, changeset} = Blocks.update_block(block, %{"type" => nil})
      assert "can't be blank" in errors_on(changeset).type
    end

    test "should validate access_rules dates (lock_at cannot be before unlock_at)" do
      block = insert(:block)

      attrs = %{
        "visibility" => "restricted",
        "access_rules" => %{
          "unlock_at" => "2026-03-20T10:00:00Z",
          "lock_at" => "2026-03-19T10:00:00Z"
        }
      }

      assert {:error, changeset} = Blocks.update_block(block, attrs)
      assert %{lock_at: ["must be after the unlock time"]} = errors_on(changeset).access_rules
    end
  end

  describe "reorder_block/2" do
    test "should change order field when moving between blocks", %{section: s} do
      _b1 = insert(:block, section: s, order: 1000)
      _b2 = insert(:block, section: s, order: 2000)
      b3 = insert(:block, section: s, order: 3000)

      assert {:ok, updated} = Blocks.reorder_block(b3, 1)

      assert updated.order == 1500
    end

    test "should handle moving to the beginning of the list", %{section: s} do
      _b1 = insert(:block, section: s, order: 1000)
      b2 = insert(:block, section: s, order: 2000)

      assert {:ok, updated} = Blocks.reorder_block(b2, 0)
      assert updated.order == 500
    end

    test "should handle moving to the end of the list", %{section: s} do
      b1 = insert(:block, section: s, order: 1000)
      _b2 = insert(:block, section: s, order: 2000)

      assert {:ok, updated} = Blocks.reorder_block(b1, 1)
      assert updated.order == 3024
    end
  end

  describe "delete_block/1" do
    test "should delete block" do
      block = insert(:block)

      assert {:ok, _} = Blocks.delete_block(block)
      assert Repo.get(Block, block.id) == nil
    end
  end

  describe "prepare_media_upload/2" do
    test "should return presigned url and meta payload for the client" do
      course_id = Ecto.UUID.generate()
      filename = "test_video.mp4"

      assert {:ok, meta} = Blocks.prepare_media_upload(course_id, filename)

      assert meta.uploader == "S3"
      assert is_binary(meta.bucket)
      assert String.starts_with?(meta.key, "courses/#{course_id}/")
      assert String.ends_with?(meta.key, "-test_video.mp4")
      assert meta.url_for_saved_entry == "/media/#{meta.key}"
      assert is_binary(meta.url)
    end
  end

  describe "attach_media_to_block/4" do
    test "should update block content with url in a transaction" do
      block = insert(:block, content: %{"controls" => true, "poster_url" => "http://img.com"})
      user_id = Ecto.UUID.generate()

      meta = %{
        bucket: "athena-test",
        key: "courses/123/uuid-test.mp4",
        url_for_saved_entry: "/athena-test/courses/123/uuid-test.mp4"
      }

      file_info = %{
        name: "test.mp4",
        type: "video/mp4",
        size: 500_000
      }

      assert {:ok, updated_block} = Blocks.attach_media_to_block(block, user_id, meta, file_info)

      assert updated_block.content["url"] == meta.url_for_saved_entry
      assert updated_block.content["controls"] == true
      assert updated_block.content["poster_url"] == "http://img.com"
    end

    test "should return error if block is invalid" do
      invalid_block = %Block{id: Ecto.UUID.generate()}
      user_id = Ecto.UUID.generate()

      meta = %{bucket: "b", key: "k", url_for_saved_entry: "url"}
      file_info = %{name: "n", type: "t", size: 10}

      assert {:error, _changeset} =
               Blocks.attach_media_to_block(invalid_block, user_id, meta, file_info)
    end
  end

  describe "get_blocks_map/1" do
    test "returns a map of blocks keyed by their IDs", %{section: s} do
      b1 = insert(:block, section: s)
      b2 = insert(:block, section: s)
      b3 = insert(:block, section: s)

      result = Blocks.get_blocks_map([b1.id, b2.id])

      assert map_size(result) == 2
      assert result[b1.id].id == b1.id
      assert result[b2.id].id == b2.id
      refute Map.has_key?(result, b3.id)
    end

    test "returns an empty map for an empty list of ids" do
      assert Blocks.get_blocks_map([]) == %{}
    end

    test "ignores non-existent ids", %{section: s} do
      b1 = insert(:block, section: s)
      fake_id = Ecto.UUID.generate()

      result = Blocks.get_blocks_map([b1.id, fake_id])

      assert map_size(result) == 1
      assert result[b1.id].id == b1.id
      refute Map.has_key?(result, fake_id)
    end
  end

  describe "get_block/2 (With ACL)" do
    setup do
      role =
        insert(:role,
          permissions: ["courses.update"],
          policies: %{"courses.update" => ["own_only"]}
        )

      instructor = insert(:account, role: role)
      other_instructor = insert(:account, role: role)
      %{instructor: instructor, other_instructor: other_instructor}
    end

    test "returns block if instructor owns the parent course", %{instructor: instructor} do
      course = insert(:course, owner_id: instructor.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      assert {:ok, fetched} = Blocks.get_block(instructor, block.id)
      assert fetched.id == block.id
    end

    test "returns not_found if instructor does not own the parent course", %{
      instructor: instructor,
      other_instructor: other_instructor
    } do
      course = insert(:course, owner_id: other_instructor.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      assert {:error, :not_found} = Blocks.get_block(instructor, block.id)
    end
  end

  describe "count_blocks_by_course/1" do
    test "returns a map with section block counts" do
      course = insert(:course)

      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      other_course = insert(:course)
      s3 = insert(:section, course: other_course)

      insert(:block, section: nil, section_id: s1.id)
      insert(:block, section: nil, section_id: s1.id)
      insert(:block, section: nil, section_id: s2.id)
      insert(:block, section: nil, section_id: s3.id)

      counts = Blocks.count_blocks_by_course(course.id)

      assert map_size(counts) == 2
      assert counts[s1.id] == 2
      assert counts[s2.id] == 1
    end

    test "returns an empty map if course has no blocks" do
      course = insert(:course)
      _section = insert(:section, course: course)

      assert Blocks.count_blocks_by_course(course.id) == %{}
    end
  end
end
