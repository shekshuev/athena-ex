defmodule Athena.Content.Library do
  @moduledoc """
  Internal business logic for reusable Library Blocks and Exam generation.
  """

  import Ecto.Query
  alias Athena.{Repo, Identity}
  alias Athena.Content.{LibraryBlock, LibraryBlockShare, Block}

  @doc "Lists library blocks with Flop pagination and filtering, scoped by ACL."
  @spec list_library_blocks(map(), map()) ::
          {:ok, {[LibraryBlock.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_library_blocks(user, params \\ %{}) do
    tag_search = Map.get(params, "tag_search")
    flop_params = Map.delete(params, "tag_search")

    query =
      from(lb in LibraryBlock)
      |> scope_library_reads(user)

    query =
      if is_binary(tag_search) and tag_search != "" do
        tags =
          tag_search
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Enum.reduce(tags, query, fn t, q ->
          term = "%#{t}%"

          where(
            q,
            [lb],
            fragment("EXISTS (SELECT 1 FROM unnest(?) AS t WHERE t ILIKE ?)", lb.tags, ^term)
          )
        end)
      else
        query
      end

    Flop.validate_and_run(query, flop_params, for: LibraryBlock)
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
    |> scope_library_reads(user)
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
    if can_edit_block?(user, block) do
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
    if can_edit_block?(user, block) do
      Repo.delete(block)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Generates a snapshot of questions for a quiz_exam based on tag rules.
  Uses PostgreSQL array intersection operator (&&) for massive performance.
  """
  @spec generate_exam_questions(map() | nil) :: [Block.t()]
  def generate_exam_questions(exam_config) when is_map(exam_config) do
    count = Map.get(exam_config, "count", 10)
    mandatory_tags = Map.get(exam_config, "mandatory_tags", [])
    include_tags = Map.get(exam_config, "include_tags", [])
    exclude_tags = Map.get(exam_config, "exclude_tags", [])

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
    |> Enum.map(fn lib_block ->
      %Block{
        id: Ecto.UUID.generate(),
        type: lib_block.type,
        content: lib_block.content,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    end)
  end

  def generate_exam_questions(_), do: []

  defp fetch_exam_blocks([], _exclude, _limit), do: []

  defp fetch_exam_blocks(tags, exclude_tags, limit, exclude_ids \\ []) do
    query =
      LibraryBlock
      |> where([lb], lb.type in [:quiz_question, :code, :file_assignment])
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

  @doc """
  Shares a library block with a specific user account (by UUID) and assigns a role.
  Updates the role if the share already exists via UPSERT.
  """
  def share_block(user, %LibraryBlock{} = block, account_id, role \\ :reader) do
    if can_edit_block?(user, block) do
      %LibraryBlockShare{}
      |> LibraryBlockShare.changeset(%{
        library_block_id: block.id,
        account_id: account_id,
        role: role
      })
      |> Repo.insert(
        on_conflict: [set: [role: role, updated_at: DateTime.utc_now(:second)]],
        conflict_target: [:library_block_id, :account_id]
      )
      |> case do
        {:ok, share} -> {:ok, share}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Revokes a specific user's access to a library block.
  """
  def revoke_block_share(user, %LibraryBlock{} = block, account_id) do
    if can_edit_block?(user, block) do
      from(s in LibraryBlockShare,
        where: s.library_block_id == ^block.id and s.account_id == ^account_id
      )
      |> Repo.delete_all()

      {:ok, :revoked}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Toggles the public visibility of a library block.
  """
  def toggle_block_public(user, %LibraryBlock{} = block, is_public) when is_boolean(is_public) do
    if can_edit_block?(user, block) do
      block
      |> Ecto.Changeset.change(%{is_public: is_public})
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns a list of maps %{account_id: id, role: role} that this block is shared with.
  """
  def list_block_shares(%LibraryBlock{} = block) do
    Repo.all(
      from s in LibraryBlockShare,
        where: s.library_block_id == ^block.id,
        select: %{account_id: s.account_id, role: s.role}
    )
  end

  @doc false
  defp scope_library_reads(query, user) do
    if Identity.can?(user, "library.read") do
      policies = Map.get(user.role.policies || %{}, "library.read", [])

      if "own_only" in policies do
        shared_block_ids =
          from s in LibraryBlockShare,
            where: s.account_id == ^user.id,
            select: s.library_block_id

        from b in query,
          where:
            b.owner_id == ^user.id or
              b.is_public == true or
              b.id in subquery(shared_block_ids)
      else
        query
      end
    else
      from b in query, where: false
    end
  end

  @doc """
  Checks whether the user can edit the block (owner or has the writer role).
  """
  def can_edit_block?(user, block) do
    if Identity.can?(user, "library.update", block) do
      true
    else
      if Identity.can?(user, "library.update") do
        Repo.exists?(
          from s in LibraryBlockShare,
            where:
              s.library_block_id == ^block.id and s.account_id == ^user.id and s.role == :writer
        )
      else
        false
      end
    end
  end
end
