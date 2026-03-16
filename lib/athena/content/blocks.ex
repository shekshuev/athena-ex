defmodule Athena.Content.Blocks do
  @moduledoc """
  Internal business logic for managing Content Blocks.

  Implements double precision indexing (gap of 1024) to allow easy 
  drag-and-drop reordering without recalculating the entire table.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Content.Block

  @doc """
  Retrieves all blocks for a specific section, ordered by their `order` index.
  """
  @spec list_blocks_by_section(String.t()) :: [Block.t()]
  def list_blocks_by_section(section_id) do
    Block
    |> where([b], b.section_id == ^section_id)
    |> order_by([b], asc: b.order)
    |> Repo.all()
  end

  @doc """
  Retrieves a single block by its ID.
  """
  @spec get_block(String.t()) :: {:ok, Block.t()} | {:error, :not_found}
  def get_block(id) do
    case Repo.get(Block, id) do
      nil -> {:error, :not_found}
      block -> {:ok, block}
    end
  end

  @doc """
  Creates a new block. 

  If `order` is not provided, it automatically calculates the next order 
  by finding the maximum order in the section and adding 1024.
  """
  @spec create_block(map()) :: {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def create_block(attrs) do
    section_id = Map.get(attrs, "section_id")
    order = Map.get(attrs, "order")

    final_order =
      if is_nil(order) and not is_nil(section_id) do
        calculate_next_order(section_id)
      else
        order || 1024
      end

    merged_attrs = Map.put(attrs, "order", final_order)

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
  """
  @spec delete_block(Block.t()) :: {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def delete_block(%Block{} = block) do
    Repo.delete(block)
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
