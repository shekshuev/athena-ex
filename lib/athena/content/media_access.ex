defmodule Athena.Content.MediaAccess do
  @moduledoc "Authorizes media referenced by readable course and library content."

  import Ecto.Query
  alias Athena.{Content, Learning, Media, Repo}
  alias Athena.Content.{Block, Courses, LibraryAccess, LibraryBlock, Section}

  def audit_storage_links do
    Map.new([blocks: Block, library: LibraryBlock], fn {name, schema} ->
      {name,
       Media.audit_link_records(fn cursor ->
         query = from b in schema, order_by: b.id, limit: 200, select: {b.id, b.content}
         query = if cursor, do: where(query, [b], b.id > ^cursor), else: query
         Repo.all(query)
       end)}
    end)
  end

  def allowed?(user, key) do
    cond do
      writable_prefix?(user, key) or library_reference?(user, key) or course_reference?(user, key) ->
        :allowed

      referenced?(key) ->
        :denied

      true ->
        :unknown
    end
  end

  # A learner cannot grant themselves a private course/library file merely
  # by pasting its key into their own answer. Content's denial is authoritative.
  defp referenced?(key) do
    Enum.any?([Block, LibraryBlock], fn schema ->
      schema
      |> where([b], fragment("strpos(?::text, ?) > 0", b.content, ^("/media/" <> key)))
      |> select([b], b.content)
      |> Repo.all()
      |> Enum.any?(&Media.references_key?(&1, key))
    end)
  end

  defp writable_prefix?(user, key) do
    with ["courses", id | _] <- String.split(key, "/"),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, course} <- Content.get_course(id) do
      Content.can_edit_course?(user, course)
    else
      _ -> false
    end
  end

  defp library_reference?(user, key) do
    LibraryBlock
    |> LibraryAccess.scope_reads(user)
    |> where([b], fragment("strpos(?::text, ?) > 0", b.content, ^("/media/" <> key)))
    |> select([b], b.content)
    |> Repo.all()
    |> Enum.any?(&Media.references_key?(&1, key))
  end

  defp course_reference?(user, key) do
    candidates =
      from(b in Block,
        join: s in Section,
        on: s.id == b.section_id,
        where: fragment("strpos(?::text, ?) > 0", b.content, ^("/media/" <> key)),
        select: {s.course_id, b.id, b.content}
      )
      |> Repo.all()
      |> Enum.filter(fn {_course, _block, content} -> Media.references_key?(content, key) end)
      |> Enum.group_by(&elem(&1, 0))

    Enum.any?(candidates, &course_allows_reference?(user, &1))
  end

  defp course_allows_reference?(user, {course_id, blocks}) do
    readable? = Courses.readable_query(user) |> where(id: ^course_id) |> Repo.exists?()

    if readable? do
      true
    else
      accessible = Learning.media_block_access(user, course_id)
      Enum.any?(blocks, fn {_course, id, _content} -> Map.has_key?(accessible, id) end)
    end
  end
end
