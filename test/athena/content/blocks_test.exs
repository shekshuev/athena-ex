defmodule Athena.Content.BlocksTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Blocks
  alias Athena.Content.Block
  import Athena.Factory

  setup do
    admin_role = insert(:role, permissions: ["admin", "courses.update"])
    admin = insert(:account, role: admin_role)

    instructor_role =
      insert(:role,
        permissions: ["courses.update"],
        policies: %{"courses.update" => ["own_only"]}
      )

    instructor = insert(:account, role: instructor_role)
    other_instructor = insert(:account, role: instructor_role)

    student = insert(:account, role: insert(:role, permissions: []))

    course = insert(:course, owner_id: admin.id)
    section = insert(:section, course: course)

    %{
      admin: admin,
      instructor: instructor,
      other_instructor: other_instructor,
      student: student,
      course: course,
      section: section
    }
  end

  describe "list_blocks_by_section/2" do
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

    test "should filter blocks based on user policies", %{
      section: s,
      student: student,
      admin: admin
    } do
      b_public = insert(:block, section: s, visibility: :enrolled, order: 1000)
      _b_hidden = insert(:block, section: s, visibility: :hidden, order: 2000)

      assert length(Blocks.list_blocks_by_section(s.id, :all)) == 2

      filtered_for_admin = Blocks.list_blocks_by_section(s.id, admin)
      assert length(filtered_for_admin) == 1
      assert hd(filtered_for_admin).id == b_public.id

      filtered_blocks = Blocks.list_blocks_by_section(s.id, student)
      assert length(filtered_blocks) == 1
      assert hd(filtered_blocks).id == b_public.id
    end
  end

  describe "get_block/1 and get_block/2 (With ACL)" do
    test "should return block by its ID (internal)" do
      block = insert(:block)
      assert {:ok, fetched} = Blocks.get_block(block.id)
      assert fetched.id == block.id
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

  describe "create_block/2" do
    test "should create block with order 1024", %{admin: admin, section: s} do
      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Hello World"},
        "section_id" => s.id
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(admin, attrs)
      assert block.type == :text
      assert block.order == 1024
      assert block.section_id == s.id
      assert block.content == %{"text" => "Hello World"}
    end

    test "should evaluate order if other blocks exists", %{admin: admin, section: s} do
      insert(:block, section: s, order: 2048)

      attrs = %{
        "type" => "code",
        "content" => %{"code" => "IO.puts(:ok)"},
        "section_id" => s.id
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(admin, attrs)
      assert block.order == 3072
    end

    test "should use order value from params", %{admin: admin, section: s} do
      insert(:block, section: s, order: 1000)

      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Injected"},
        "section_id" => s.id,
        "order" => 500
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(admin, attrs)
      assert block.order == 500
    end

    test "should insert block between two existing blocks using after_id", %{
      admin: admin,
      section: s
    } do
      b1 = insert(:block, section: s, order: 1000)
      _b2 = insert(:block, section: s, order: 2000)

      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Inserted"},
        "section_id" => s.id,
        "after_id" => b1.id
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(admin, attrs)
      assert block.order == 1500
    end

    test "should insert block at the end if after_id is the last block", %{
      admin: admin,
      section: s
    } do
      _b1 = insert(:block, section: s, order: 1000)
      b2 = insert(:block, section: s, order: 2000)

      attrs = %{
        "type" => "text",
        "content" => %{"text" => "Inserted at end"},
        "section_id" => s.id,
        "after_id" => b2.id
      }

      assert {:ok, %Block{} = block} = Blocks.create_block(admin, attrs)
      assert block.order == 3024
    end

    test "returns error on invalid params", %{admin: admin} do
      attrs = %{"type" => "text"}

      assert {:error, changeset} = Blocks.create_block(admin, attrs)
      assert changeset == :unauthorized
    end

    test "returns unauthorized if user lacks edit rights on course", %{
      student: student,
      section: s
    } do
      attrs = %{"type" => "text", "section_id" => s.id}
      assert {:error, :unauthorized} = Blocks.create_block(student, attrs)
    end
  end

  describe "update_block/3" do
    test "should update block", %{admin: admin, section: s} do
      block = insert(:block, section: s, type: :text, content: %{"text" => "Old text"})

      attrs = %{"content" => %{"text" => "New text"}}

      assert {:ok, updated} = Blocks.update_block(admin, block, attrs)
      assert updated.content == %{"text" => "New text"}
    end

    test "should return error on invalid params", %{admin: admin, section: s} do
      block = insert(:block, section: s)

      assert {:error, changeset} = Blocks.update_block(admin, block, %{"type" => nil})
      assert "can't be blank" in errors_on(changeset).type
    end

    test "returns unauthorized if user lacks edit rights", %{student: student, section: s} do
      block = insert(:block, section: s)
      assert {:error, :unauthorized} = Blocks.update_block(student, block, %{"type" => "code"})
    end
  end

  describe "reorder_block/3" do
    test "should change order field when moving between blocks", %{admin: admin, section: s} do
      _b1 = insert(:block, section: s, order: 1000)
      _b2 = insert(:block, section: s, order: 2000)
      b3 = insert(:block, section: s, order: 3000)

      assert {:ok, updated} = Blocks.reorder_block(admin, b3, 1)
      assert updated.order == 1500
    end

    test "should handle moving to the beginning of the list", %{admin: admin, section: s} do
      _b1 = insert(:block, section: s, order: 1000)
      b2 = insert(:block, section: s, order: 2000)

      assert {:ok, updated} = Blocks.reorder_block(admin, b2, 0)
      assert updated.order == 500
    end

    test "should handle moving to the end of the list", %{admin: admin, section: s} do
      b1 = insert(:block, section: s, order: 1000)
      _b2 = insert(:block, section: s, order: 2000)

      assert {:ok, updated} = Blocks.reorder_block(admin, b1, 1)
      assert updated.order == 3024
    end

    test "returns unauthorized if user lacks edit rights", %{student: student, section: s} do
      b1 = insert(:block, section: s)
      assert {:error, :unauthorized} = Blocks.reorder_block(student, b1, 1)
    end
  end

  describe "delete_block/2" do
    test "should delete block", %{admin: admin, section: s} do
      block = insert(:block, section: s)

      assert {:ok, _} = Blocks.delete_block(admin, block)
      assert Repo.get(Block, block.id) == nil
    end

    test "returns unauthorized if user lacks edit rights", %{student: student, section: s} do
      block = insert(:block, section: s)
      assert {:error, :unauthorized} = Blocks.delete_block(student, block)
    end
  end

  describe "prepare_media_upload/3" do
    test "should return presigned url and meta payload", %{admin: admin, course: c} do
      filename = "test_video.mp4"

      assert {:ok, meta} = Blocks.prepare_media_upload(admin, c.id, filename)

      assert meta.uploader == "S3"
      assert is_binary(meta.bucket)
      assert String.starts_with?(meta.key, "courses/#{c.id}/")
      assert String.ends_with?(meta.key, "-test_video.mp4")
      assert meta.url_for_saved_entry == "/media/#{meta.key}"
      assert is_binary(meta.url)
    end

    test "returns unauthorized if user lacks edit rights", %{student: student, course: c} do
      assert {:error, :unauthorized} = Blocks.prepare_media_upload(student, c.id, "test.mp4")
    end
  end

  describe "attach_media_to_block/4" do
    test "should update block content with url in a transaction", %{admin: admin, section: s} do
      block =
        insert(:block,
          section: s,
          content: %{"controls" => true, "poster_url" => "http://img.com"}
        )

      meta = %{
        bucket: "athena-test",
        key: "courses/123/uuid-test.mp4",
        url_for_saved_entry: "/athena-test/courses/123/uuid-test.mp4",
        url: "http://s3.local"
      }

      file_info = %{
        name: "test.mp4",
        type: "video/mp4",
        size: 500_000
      }

      assert {:ok, updated_block} = Blocks.attach_media_to_block(admin, block, meta, file_info)

      assert updated_block.content["url"] == meta.url_for_saved_entry
      assert updated_block.content["controls"] == true
      assert updated_block.content["poster_url"] == "http://img.com"
    end

    test "returns unauthorized if user lacks edit rights", %{student: student, section: s} do
      block = insert(:block, section: s)
      meta = %{bucket: "b", key: "k", url_for_saved_entry: "url"}
      file_info = %{name: "n", type: "t", size: 10}

      assert {:error, :unauthorized} =
               Blocks.attach_media_to_block(student, block, meta, file_info)
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
  end
end
