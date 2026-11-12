defmodule Athena.Content.SearchIndexTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content.{Block, Blocks, SearchIndex}
  alias Athena.Content.Workers.IndexBlockSearch

  setup do
    admin = insert(:account, role: build(:role, permissions: ["admin", "courses.update"]))
    section = insert(:section, course: build(:course, owner_id: admin.id))
    %{admin: admin, section: section}
  end

  test "creation stores a deadline and a durable job without extracting text", ctx do
    before = DateTime.utc_now()
    assert {:ok, block} = create_block(ctx)
    after_save = DateTime.utc_now()

    assert is_nil(block.search_text)
    assert DateTime.compare(block.search_due_at, DateTime.add(before, 60)) != :lt
    assert DateTime.compare(block.search_due_at, DateTime.add(after_save, 60)) != :gt
    assert Repo.get!(Block, block.id).search_due_at == block.search_due_at
    assert [job] = jobs(block)
    assert job.state == "scheduled"
    assert job.scheduled_at == block.search_due_at
    assert job.queue == "search_index"
  end

  test "successive content edits move the same scheduled job", ctx do
    {:ok, block} = create_block(ctx)
    [first_job] = jobs(block)

    {:ok, edited} = Blocks.update_block(ctx.admin, block, %{"content" => doc("Second")})
    {:ok, edited} = Blocks.update_block(ctx.admin, edited, %{"content" => doc("Third")})

    assert [job] = jobs(edited)
    assert job.id == first_job.id
    assert job.scheduled_at == edited.search_due_at
    assert DateTime.compare(job.scheduled_at, first_job.scheduled_at) == :gt
    assert is_nil(edited.search_text)
  end

  test "metadata and identical content do not invalidate an indexed block", ctx do
    block = insert(:block, section: ctx.section, content: doc("Current"), search_text: "Current")

    assert {:ok, updated} =
             Blocks.update_block(ctx.admin, block, %{
               "content" => doc("Current"),
               "points" => 2,
               "visibility" => "hidden",
               "access_rules" => %{"reset_waterline" => true}
             })

    assert updated.search_text == "Current"
    assert is_nil(updated.search_due_at)
    assert jobs(block) == []
  end

  test "a type change schedules removal of the previous searchable text", ctx do
    block = insert(:block, section: ctx.section, content: doc("Old"), search_text: "Old")
    assert {:ok, updated} = Blocks.update_block(ctx.admin, block, %{"type" => "image"})

    assert updated.type == :image
    assert updated.search_due_at
    assert [_] = jobs(updated)
  end

  test "client params cannot supply derived fields", ctx do
    assert {:ok, block} =
             Blocks.create_block(ctx.admin, %{
               "type" => "text",
               "content" => doc("Safe"),
               "section_id" => ctx.section.id,
               "search_text" => "INJECTED",
               "search_due_at" => nil
             })

    assert is_nil(block.search_text)
    assert block.search_due_at
  end

  test "outer transaction rollback removes both the block and its task", ctx do
    block_id = Ecto.UUID.generate()

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        %Block{
                          id: block_id,
                          section_id: ctx.section.id,
                          type: :text,
                          content: doc("X")
                        }
                        |> SearchIndex.insert()

               Repo.rollback(:abort)
             end)

    refute Repo.get(Block, block_id)
    assert jobs(%Block{id: block_id}) == []
  end

  test "outer rollback also restores existing content, deadline and scheduled task", ctx do
    {:ok, block} = create_block(ctx)
    [job] = jobs(block)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Blocks.update_block(ctx.admin, block, %{"content" => doc("Rolled back")})

               Repo.rollback(:abort)
             end)

    assert Repo.get!(Block, block.id).content == block.content
    assert Repo.get!(Block, block.id).search_due_at == block.search_due_at
    assert Repo.get!(Oban.Job, job.id).scheduled_at == job.scheduled_at
  end

  test "invalid content does not create or move a task", ctx do
    {:ok, block} = create_block(ctx)
    [job] = jobs(block)

    assert {:error, %Ecto.Changeset{}} =
             Blocks.update_block(ctx.admin, block, %{"type" => "quiz_question", "content" => %{}})

    assert Repo.get!(Block, block.id).content == block.content
    assert [unchanged] = jobs(block)
    assert unchanged.scheduled_at == job.scheduled_at
  end

  test "available, executing, retryable and finished tasks never swallow a new edit", ctx do
    for state <- ~w(available executing retryable completed cancelled discarded) do
      {:ok, block} = create_block(ctx)
      [old_job] = jobs(block)
      old_job |> Ecto.Changeset.change(state: state) |> Repo.update!()

      assert {:ok, edited} = Blocks.update_block(ctx.admin, block, %{"content" => doc(state)})

      assert [new_job] = Enum.filter(jobs(block), &(&1.state == "scheduled"))
      assert new_job.id != old_job.id
      assert new_job.scheduled_at == edited.search_due_at
    end
  end

  test "duplication schedules the new block independently", ctx do
    original =
      insert(:block, section: ctx.section, content: doc("Copy me"), search_text: "Copy me")

    assert {:ok, copy} = Blocks.duplicate_block(ctx.admin, original)
    assert is_nil(copy.search_text)
    assert copy.search_due_at
    assert [_] = jobs(copy)
    assert jobs(original) == []
  end

  test "media attachment atomically schedules the changed block", ctx do
    block = insert(:block, section: ctx.section, type: :image)

    meta = %{
      bucket: "athena-test",
      key: "search/test.png",
      url_for_saved_entry: "/media/search/test.png"
    }

    file = %{name: "test.png", type: "image/png", size: 10}

    assert {:ok, updated} = Blocks.attach_media_to_block(ctx.admin, block, meta, file)
    assert updated.content["url"] == meta.url_for_saved_entry
    assert updated.search_due_at
    assert [_] = jobs(updated)
  end

  test "header queries do not load the derived text", ctx do
    block = insert(:block, section: ctx.section, search_text: String.duplicate("Large", 1_000))

    assert {:ok, header} = Blocks.get_block_header(block.id)
    assert is_nil(header.search_text)
    assert [%Block{search_text: nil}] = Blocks.list_block_headers_by_section_ids([ctx.section.id])
    assert %{search_text: nil} = Blocks.get_blocks_map([block.id])[block.id]
  end

  test "both search indexes are valid" do
    result =
      Repo.query!("""
      SELECT c.relname, i.indisvalid, pg_get_indexdef(i.indexrelid)
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname IN ('blocks__search_text_trgm__idx', 'blocks__search_due_at__idx')
      """)

    assert length(result.rows) == 2
    assert Enum.all?(result.rows, fn [_, valid?, _] -> valid? end)

    assert Enum.any?(result.rows, fn [_, _, definition] ->
             String.contains?(definition, "gin_trgm_ops")
           end)

    assert Enum.any?(result.rows, fn [_, _, definition] ->
             String.contains?(definition, "WHERE (search_due_at IS NOT NULL)")
           end)
  end

  defp create_block(ctx) do
    Blocks.create_block(ctx.admin, %{
      "type" => "text",
      "content" => doc("First"),
      "section_id" => ctx.section.id
    })
  end

  defp jobs(block) do
    from(j in Oban.Job,
      where: j.worker == ^Oban.Worker.to_string(IndexBlockSearch),
      where: fragment("? ->> 'block_id'", j.args) == ^block.id,
      order_by: j.id
    )
    |> Repo.all()
  end

  defp doc(value) do
    %{
      "type" => "doc",
      "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => value}]}]
    }
  end
end
