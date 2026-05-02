defmodule Athena.Content.Library do
  @moduledoc """
  Internal business logic for reusable Library Blocks and Exam generation.
  """

  import Ecto.Query
  alias Athena.{Repo, Identity}
  alias Athena.Content.LibraryBlock

  @doc "Lists library blocks with Flop pagination and filtering, scoped by ACL."
  @spec list_library_blocks(map(), map()) ::
          {:ok, {[LibraryBlock.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_library_blocks(user, params \\ %{}) do
    from(lb in LibraryBlock)
    |> Identity.scope_query(user, "library.read")
    |> Flop.validate_and_run(params, for: LibraryBlock)
  end

  @doc "Retrieves a single library block without ACL (internal use)."
  @spec get_library_block(String.t()) :: {:ok, LibraryBlock.t()} | {:error, :not_found}
  def get_library_block(id) do
    case Repo.get(LibraryBlock, id) do
      nil -> {:error, :not_found}
      block -> {:ok, block}
    end
  end

  @doc "Retrieves a single library block, scoped by ACL."
  @spec get_library_block(map(), String.t()) :: {:ok, LibraryBlock.t()} | {:error, :not_found}
  def get_library_block(user, id) do
    LibraryBlock
    |> where([lb], lb.id == ^id)
    |> Identity.scope_query(user, "library.read")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      block -> {:ok, block}
    end
  end

  @doc "Creates a new library block template. Sets owner to current user."
  @spec create_library_block(map(), map()) ::
          {:ok, LibraryBlock.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_library_block(user, attrs) do
    if Identity.can?(user, "library.update") do
      %LibraryBlock{owner_id: user.id}
      |> LibraryBlock.changeset(attrs)
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc "Updates a library block template. Checks own_only policies."
  @spec update_library_block(map(), LibraryBlock.t(), map()) ::
          {:ok, LibraryBlock.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_library_block(user, %LibraryBlock{} = block, attrs) do
    if Identity.can?(user, "library.update", block) do
      block
      |> LibraryBlock.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc "Deletes a library block template. Checks own_only policies."
  @spec delete_library_block(map(), LibraryBlock.t()) ::
          {:ok, LibraryBlock.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_library_block(user, %LibraryBlock{} = block) do
    if Identity.can?(user, "library.update", block) do
      Repo.delete(block)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Generates a snapshot of questions for a Quiz Exam based on tag rules.
  Uses PostgreSQL array intersection operator (&&) for massive performance.
  """
  @spec generate_exam_questions(map()) :: [map()]
  def generate_exam_questions(%{
        "count" => count,
        "mandatory_tags" => mandatory_tags,
        "include_tags" => include_tags,
        "exclude_tags" => exclude_tags
      }) do
    mandatory_blocks = fetch_exam_blocks(mandatory_tags, exclude_tags, count)

    remaining_count = count - length(mandatory_blocks)

    random_blocks =
      if remaining_count > 0 and include_tags != [] do
        mandatory_ids = Enum.map(mandatory_blocks, & &1.id)

        fetch_exam_blocks(include_tags, exclude_tags, remaining_count, mandatory_ids)
      else
        []
      end

    (mandatory_blocks ++ random_blocks)
    |> Enum.shuffle()
    |> Enum.map(fn block ->
      content = block.content

      %{
        id: Ecto.UUID.generate(),
        original_block_id: block.id,
        type: Map.get(content, "question_type"),
        question: Map.get(content, "body"),
        options: Map.get(content, "options"),
        correct_answer_text: Map.get(content, "correct_answer"),
        explanation: Map.get(content, "general_explanation")
      }
    end)
  end

  defp fetch_exam_blocks([], _exclude, _limit), do: []

  defp fetch_exam_blocks(tags, exclude_tags, limit, exclude_ids \\ []) do
    query =
      LibraryBlock
      |> where([lb], lb.type == :quiz_question)
      |> where([lb], fragment("? && ?", lb.tags, ^tags))

    query =
      if exclude_tags != [] do
        where(query, [lb], not fragment("? && ?", lb.tags, ^exclude_tags))
      else
        query
      end

    query =
      if exclude_ids != [] do
        where(query, [lb], lb.id not in ^exclude_ids)
      else
        query
      end

    query
    |> order_by(fragment("RANDOM()"))
    |> limit(^limit)
    |> Repo.all()
  end
end
