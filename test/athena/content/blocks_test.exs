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
  end

  describe "reorder_block/2" do
    test "should change order field" do
      block = insert(:block, order: 1024)

      assert {:ok, updated} = Blocks.reorder_block(block, 1500)
      assert updated.order == 1500
    end
  end

  describe "delete_block/1" do
    test "should delete block" do
      block = insert(:block)

      assert {:ok, _} = Blocks.delete_block(block)
      assert Repo.get(Block, block.id) == nil
    end
  end
end
