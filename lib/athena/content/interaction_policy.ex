defmodule Athena.Content.InteractionPolicy do
  @moduledoc "Resolves interaction modes independently of visibility and progression."
  import Ecto.Query

  alias Athena.Content.{Block, Section}
  alias Athena.Repo

  @doc "Resolves a block or section, using supplied section headers when available."
  def readonly?(item, sections \\ %{})
  def readonly?(nil, _sections), do: false
  def readonly?(%{interaction_mode: :readonly}, _sections), do: true
  def readonly?(%{interaction_mode: :interactive}, _sections), do: false

  def readonly?(%Block{section_id: id}, sections),
    do: readonly?(section(id, sections), sections)

  def readonly?(%Section{parent_id: nil}, _sections), do: false

  def readonly?(%Section{parent_id: id}, sections),
    do: readonly?(section(id, sections), sections)

  @doc "Checks current persisted policy without loading block content."
  def block_readonly?(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Block
        |> where([b], b.id == ^id)
        |> select([b], struct(b, [:id, :section_id, :interaction_mode]))
        |> Repo.one()
        |> readonly?()

      :error ->
        false
    end
  end

  @doc "Resolves many blocks with one query for their courses' section headers."
  def readonly_block_ids([]), do: MapSet.new()

  def readonly_block_ids(blocks) do
    section_ids = Enum.map(blocks, & &1.section_id)
    courses = from(s in Section, where: s.id in ^section_ids, select: s.course_id)

    sections =
      from(s in Section,
        where: s.course_id in subquery(courses),
        select: struct(s, [:id, :parent_id, :interaction_mode])
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    blocks |> Enum.filter(&readonly?(&1, sections)) |> MapSet.new(& &1.id)
  end

  defp section(id, sections) do
    case Map.fetch(sections, id) do
      {:ok, section} ->
        section

      :error ->
        Repo.one(
          from(s in Section,
            where: s.id == ^id,
            select: struct(s, [:id, :parent_id, :interaction_mode])
          )
        )
    end
  end
end
