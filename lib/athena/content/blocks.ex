defmodule Athena.Content.Blocks do
  @moduledoc """
  Internal business logic for managing Content Blocks.

  Implements double precision indexing (gap of 1024) to allow easy 
  drag-and-drop reordering without recalculating the entire table.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Content.{Block, Course, Section}

  @doc """
  Retrieves all blocks for a specific section, ordered by their `order` index.
  If a user is provided, filters the blocks based on access policies.
  """
  @spec list_blocks_by_section(String.t(), Athena.Identity.Account.t() | nil | :all) :: [
          Block.t()
        ]
  def list_blocks_by_section(section_id, user_or_mode \\ :all) do
    blocks =
      Block
      |> where([b], b.section_id == ^section_id)
      |> order_by([b], asc: b.order)
      |> Repo.all()

    if user_or_mode == :all do
      blocks
    else
      Enum.filter(blocks, &Athena.Content.Policy.can_view?(user_or_mode, &1))
    end
  end

  @doc """
  Retrieves all blocks for multiple sections.
  Used for bulk operations like calculating course-wide unlock schedules.
  """
  @spec list_blocks_by_section_ids([String.t()]) :: [Block.t()]
  def list_blocks_by_section_ids(section_ids) do
    Block
    |> where([b], b.section_id in ^section_ids)
    |> Repo.all()
  end

  @doc """
  Retrieves a single block by its ID without ACL (internal/student use).
  """
  @spec get_block(String.t()) :: {:ok, Block.t()} | {:error, :not_found}
  def get_block(id) do
    case Repo.get(Block, id) do
      nil -> {:error, :not_found}
      block -> {:ok, block}
    end
  end

  @doc """
  Retrieves a single block by its ID, scoped by user ACL permissions on the parent course.
  """
  @spec get_block(map(), String.t()) :: {:ok, Block.t()} | {:error, :not_found}
  def get_block(user, id) do
    accessible_courses =
      Course
      |> where([c], is_nil(c.deleted_at))
      |> Athena.Identity.scope_query(user, "courses.update")

    Block
    |> join(:inner, [b], s in Section, on: b.section_id == s.id)
    |> join(:inner, [b, s], c in subquery(accessible_courses), on: s.course_id == c.id)
    |> where([b], b.id == ^id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      block -> {:ok, block}
    end
  end

  @doc """
  Creates a new block. 

  If `order` is provided, it uses it directly.
  If `after_id` is provided, it calculates the order to place the new block immediately after it.
  If neither is provided, it automatically calculates the next order 
  by finding the maximum order in the section and adding 1024.
  """
  @spec create_block(map()) :: {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def create_block(attrs) do
    section_id = Map.get(attrs, "section_id")
    order = Map.get(attrs, "order")
    after_id = Map.get(attrs, "after_id")

    final_order =
      cond do
        not is_nil(order) ->
          order

        not is_nil(after_id) and not is_nil(section_id) ->
          calculate_order_after(section_id, after_id)

        not is_nil(section_id) ->
          calculate_next_order(section_id)

        true ->
          1024
      end

    merged_attrs =
      attrs
      |> Map.put("order", final_order)
      |> Map.delete("after_id")
      |> Map.delete(:after_id)

    %Block{}
    |> Block.changeset(merged_attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing block's content or type.
  """
  @spec update_block(Block.t(), map()) :: {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def update_block(%Block{} = block, attrs) do
    block
    |> Block.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Reorders a block by moving it to a new index within its section.
  Calculates the gap-based order automatically.
  """
  @spec reorder_block(Block.t(), integer()) :: {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def reorder_block(%Block{} = block, new_index) do
    blocks =
      Block
      |> where([b], b.section_id == ^block.section_id and b.id != ^block.id)
      |> order_by([b], asc: b.order)
      |> Repo.all()

    reordered = List.insert_at(blocks, new_index, block)

    prev = if new_index > 0, do: Enum.at(reordered, new_index - 1), else: nil
    next = Enum.at(reordered, new_index + 1)

    new_order =
      cond do
        is_nil(prev) ->
          if next, do: div(next.order, 2), else: 1024

        is_nil(next) ->
          prev.order + 1024

        true ->
          div(prev.order + next.order, 2)
      end

    block
    |> Ecto.Changeset.change(%{order: new_order})
    |> Repo.update()
  end

  @doc """
  Permanently deletes a block. 
  Media cleanup is handled asynchronously by Oban (Athena.Workers.MediaCleanup).
  """
  @spec delete_block(Block.t()) :: {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def delete_block(%Block{} = block) do
    Repo.delete(block)
  end

  @doc """
  Prepares data for direct upload to S3
  """
  def prepare_media_upload(course_id, filename) do
    bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena"

    unique_filename = "#{Ecto.UUID.generate()}-#{filename}"
    key = "courses/#{course_id}/#{unique_filename}"

    case Athena.Media.generate_upload_url(bucket, key) do
      {:ok, presigned_url} ->
        local_url = "/media/#{key}"

        meta = %{
          uploader: "S3",
          url: presigned_url,
          url_for_saved_entry: local_url,
          bucket: bucket,
          key: key
        }

        {:ok, meta}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a file entry in Media and attaches its URL to the block's content.
  Executed in a single database transaction.
  """
  def attach_media_to_block(%Block{} = block, user_id, meta, file_info) do
    file_attrs = %{
      "bucket" => meta.bucket,
      "key" => meta.key,
      "original_name" => file_info.name,
      "mime_type" => file_info.type,
      "size" => file_info.size,
      "context" => "course_material",
      "owner_id" => user_id
    }

    new_content = Map.put(block.content || %{}, "url", meta.url_for_saved_entry)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:file, fn _repo, _changes ->
      Athena.Media.create_file(file_attrs)
    end)
    |> Ecto.Multi.update(:block, Block.changeset(block, %{"content" => new_content}))
    |> Repo.transaction()
    |> case do
      {:ok, %{block: updated_block}} ->
        {:ok, updated_block}

      {:error, _failed_operation, failed_value, _changes_so_far} ->
        {:error, failed_value}
    end
  end

  @doc """
  Returns a map of blocks by their IDs
  """
  def get_blocks_map(ids) do
    Block
    |> where([b], b.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Returns a map of %{section_id => blocks_count} for all sections in a course.
  """
  def count_blocks_by_course(course_id) do
    Block
    |> join(:inner, [b], s in Section, on: b.section_id == s.id)
    |> where([b, s], s.course_id == ^course_id)
    |> group_by([b], b.section_id)
    |> select([b], {b.section_id, count(b.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc false
  defp calculate_order_after(section_id, after_id) do
    blocks =
      Block
      |> where([b], b.section_id == ^section_id)
      |> order_by([b], asc: b.order)
      |> Repo.all()

    case Enum.find_index(blocks, &(&1.id == after_id)) do
      nil ->
        calculate_next_order(section_id)

      index ->
        prev_block = Enum.at(blocks, index)
        next_block = Enum.at(blocks, index + 1)

        if is_nil(next_block) do
          prev_block.order + 1024
        else
          div(prev_block.order + next_block.order, 2)
        end
    end
  end

  @doc false
  defp calculate_next_order(section_id) do
    max_order =
      Repo.one(
        from b in Block,
          where: b.section_id == ^section_id,
          select: max(b.order)
      )

    (max_order || 0) + 1024
  end
end
