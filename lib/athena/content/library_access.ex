defmodule Athena.Content.LibraryAccess do
  @moduledoc """
  Library read, editing and management scopes. Course access is evaluated on
  every request; it never creates permanent shares on individual templates.
  Course writers may edit pinned templates owned by that course's owner, but
  receive no inherited ability to delete, reshare or publish those templates.
  """
  import Ecto.Query
  alias Athena.{Identity, Repo}
  alias Athena.Content.{Courses, CourseLibraryBlock, LibraryBlock, LibraryBlockShare}

  @no_access %{
    role: :none,
    can_edit: false,
    can_manage: false,
    can_delete: false,
    shares_count: 0
  }

  def scope_reads(query, user) do
    cond do
      not Identity.can?(user, "library.read") -> where(query, false)
      not own_only?(user, "library.read") -> query
      true -> scope_owned_shared_or_pinned(query, user)
    end
  end

  def readable?(user, id) do
    LibraryBlock |> where(id: ^id) |> scope_reads(user) |> Repo.exists?()
  end

  def editable?(user, block), do: permitted?(user, block.id, "library.update", true)
  def manageable?(user, block), do: permitted?(user, block.id, "library.update", false)
  def deletable?(user, block), do: permitted?(user, block.id, "library.delete", false)

  def for_blocks(user, blocks) do
    ids = Enum.map(blocks, & &1.id)
    query = where(LibraryBlock, [b], b.id in ^ids)
    readable = query |> scope_reads(user) |> select([b], {b.id, b.owner_id}) |> Repo.all()
    writable = permission_ids(query, user, "library.update", true)
    manageable = permission_ids(query, user, "library.update", false)
    deletable = permission_ids(query, user, "library.delete", false)

    share_counts =
      from(s in LibraryBlockShare,
        where: s.library_block_id in ^ids,
        group_by: s.library_block_id,
        select: {s.library_block_id, count(s.id)}
      )
      |> Repo.all()
      |> Map.new()

    access =
      Map.new(readable, fn {id, owner_id} ->
        edit? = MapSet.member?(writable, id)

        access = %{
          role: role(edit?, owner_id == user.id),
          can_edit: edit?,
          can_manage: MapSet.member?(manageable, id),
          can_delete: MapSet.member?(deletable, id),
          shares_count: Map.get(share_counts, id, 0)
        }

        {id, access}
      end)

    Map.merge(Map.new(ids, &{&1, @no_access}), access)
  end

  def for_block(user, block), do: Map.get(for_blocks(user, [block]), block.id, @no_access)

  defp role(true, true), do: :owner
  defp role(true, false), do: :writer
  defp role(false, _owner?), do: :reader

  defp scope_owned_shared_or_pinned(query, user) do
    shares =
      from s in LibraryBlockShare, where: s.account_id == ^user.id, select: s.library_block_id

    courses = Courses.readable_query(user) |> select([c], c.id)

    pins =
      from p in CourseLibraryBlock,
        where: p.course_id in subquery(courses),
        select: p.library_block_id

    where(
      query,
      [b],
      b.owner_id == ^user.id or b.is_public or b.id in subquery(shares) or b.id in subquery(pins)
    )
  end

  defp permitted?(user, id, permission, inherit?) do
    LibraryBlock
    |> where(id: ^id)
    |> scope_permission(user, permission, inherit?)
    |> Repo.exists?()
  end

  defp permission_ids(query, user, permission, inherit?) do
    query
    |> scope_permission(user, permission, inherit?)
    |> select([b], b.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp scope_permission(query, user, permission, inherit?) do
    cond do
      not Identity.can?(user, permission) -> where(query, false)
      not own_only?(user, permission) -> query
      true -> scope_delegated_writes(query, user, inherit?)
    end
  end

  defp scope_delegated_writes(query, user, inherit?) do
    shares =
      from s in LibraryBlockShare,
        where: s.account_id == ^user.id and s.role == :writer,
        select: s.library_block_id

    inherited = inherited_block_ids(user, inherit?)

    where(
      query,
      [b],
      b.owner_id == ^user.id or b.id in subquery(shares) or b.id in subquery(inherited)
    )
  end

  defp inherited_block_ids(user, true) do
    courses = Courses.editable_query(user) |> select([c], %{id: c.id, owner_id: c.owner_id})

    query =
      from b in LibraryBlock,
        join: p in CourseLibraryBlock,
        on: p.library_block_id == b.id,
        join: c in subquery(courses),
        on: c.id == p.course_id and c.owner_id == b.owner_id,
        select: b.id

    if Identity.can?(user, "library.read"), do: query, else: where(query, false)
  end

  defp inherited_block_ids(_user, false), do: from(b in LibraryBlock, where: false, select: b.id)

  defp own_only?(user, permission),
    do: "own_only" in Map.get(user.role.policies || %{}, permission, [])
end
