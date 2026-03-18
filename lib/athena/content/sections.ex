defmodule Athena.Content.Sections do
  @moduledoc """
  Internal business logic for Section management and hierarchy building.

  This module handles the lifecycle of sections and uses PostgreSQL `ltree`
  to manage deep nesting. It provides a highly efficient way to reconstruct
  the course structure in-memory.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Content.Section

  @doc """
  Retrieves a single section by its ID.
  """
  @spec get_section(String.t()) :: {:ok, Section.t()} | {:error, :not_found}
  def get_section(id) do
    case Repo.get(Section, id) do
      nil -> {:error, :not_found}
      section -> {:ok, section}
    end
  end

  @doc """
  Creates a new section. 

  The `path` is automatically computed based on the `parent_id`.
  """
  @spec create_section(map()) :: {:ok, Section.t()} | {:error, Ecto.Changeset.t()}
  def create_section(attrs) do
    section_id = Map.get(attrs, "id") || Ecto.UUID.generate()
    parent_id = Map.get(attrs, "parent_id")
    parent_path = get_parent_path(parent_id)

    path_string = Section.build_path(section_id, parent_path)
    merged_attrs = Map.merge(attrs, %{"path" => path_string, "id" => section_id})

    %Section{id: section_id}
    |> Section.changeset(merged_attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing section.

  If the `parent_id` is changed, this automatically recalculates the `ltree` path
  for the section and ALL its descendant sections in the tree to keep the hierarchy consistent.
  """
  @spec update_section(Section.t(), map()) :: {:ok, Section.t()} | {:error, Ecto.Changeset.t()}
  def update_section(%Section{} = section, attrs) do
    new_parent_id = Map.get(attrs, "parent_id", Map.get(attrs, :parent_id, :not_provided))

    if parent_id_changed?(section.parent_id, new_parent_id) do
      handle_parent_id_change(section, attrs, new_parent_id)
    else
      section
      |> Section.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Deletes a section physically from the database.

  Due to the `on_delete: :delete_all` constraint in the migration, 
  deleting a parent section will automatically remove all its descendants.
  """
  @spec delete_section(Section.t()) :: {:ok, Section.t()} | {:error, Ecto.Changeset.t()}
  def delete_section(%Section{} = section) do
    Repo.delete(section)
  end

  @doc """
  Fetches all sections for a course and builds a nested tree structure.
  If a user is provided, filters the tree based on access policies.
  """
  @spec get_course_tree(String.t(), Athena.Identity.Account.t() | nil | :all) :: [Section.t()]
  def get_course_tree(course_id, user_or_mode \\ :all) do
    sections =
      Section
      |> where([s], s.course_id == ^course_id)
      |> order_by([s], asc: s.order, asc: s.inserted_at)
      |> Repo.all()

    build_tree(sections, nil, user_or_mode)
  end

  @spec build_tree([Section.t()], String.t() | nil, any()) :: [Section.t()]
  defp build_tree(sections, parent_id, user_or_mode) do
    sections
    |> Enum.filter(fn section ->
      section.parent_id == parent_id and
        (user_or_mode == :all or Athena.Content.Policy.can_view?(user_or_mode, section))
    end)
    |> Enum.map(fn section ->
      children = build_tree(sections, section.id, user_or_mode)
      Map.put(section, :children, children)
    end)
  end

  @doc """
  Reorders a section among its siblings.
  """
  @spec reorder_section(Section.t(), integer()) :: {:ok, map()} | {:error, any()}
  def reorder_section(%Section{} = section, new_index) when is_integer(new_index) do
    query =
      if is_nil(section.parent_id) do
        where(Section, [s], s.course_id == ^section.course_id and is_nil(s.parent_id))
      else
        where(
          Section,
          [s],
          s.course_id == ^section.course_id and s.parent_id == ^section.parent_id
        )
      end

    siblings =
      query
      |> order_by([s], asc: s.order, asc: s.inserted_at)
      |> Repo.all()

    siblings_without_section = Enum.reject(siblings, &(&1.id == section.id))
    updated_siblings = List.insert_at(siblings_without_section, new_index, section)

    Repo.transaction(fn ->
      updated_siblings
      |> Enum.with_index()
      |> Enum.each(&update_sibling_order(&1, section.id))
    end)

    {:ok, %{section | order: new_index}}
  end

  defp update_sibling_order({sib, index}, moved_section_id) do
    if sib.id == moved_section_id or sib.order != index do
      sib
      |> Ecto.Changeset.change(%{order: index})
      |> Repo.update!()
    end
  end

  defp parent_id_changed?(_old_id, :not_provided), do: false
  defp parent_id_changed?(old_id, new_id), do: old_id != new_id

  defp get_parent_path(nil), do: nil

  defp get_parent_path(parent_id) do
    case Repo.get(Section, parent_id) do
      nil -> nil
      parent -> parent.path
    end
  end

  defp handle_parent_id_change(section, attrs, new_parent_id) do
    Repo.transaction(fn ->
      new_parent_path = get_parent_path(new_parent_id)
      new_path_str = Section.build_path(section.id, new_parent_path)
      merged_attrs = Map.merge(attrs, %{"path" => new_path_str})

      old_path_str = Enum.join(section.path.labels, ".")

      case section |> Section.changeset(merged_attrs) |> Repo.update() do
        {:ok, updated_section} ->
          update_descendants_paths(updated_section.course_id, old_path_str, new_path_str)
          updated_section

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp update_descendants_paths(course_id, old_path_str, new_path_str) do
    Section
    |> where([s], s.course_id == ^course_id)
    |> Repo.all()
    |> Enum.each(fn s ->
      current_path_str = Enum.join(s.path.labels, ".")

      if String.starts_with?(current_path_str, old_path_str <> ".") do
        new_child_path = String.replace_prefix(current_path_str, old_path_str, new_path_str)

        s
        |> Ecto.Changeset.cast(%{"path" => new_child_path}, [:path])
        |> Repo.update!()
      end
    end)
  end
end
