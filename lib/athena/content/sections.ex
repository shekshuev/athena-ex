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

    parent_path =
      if parent_id do
        case Repo.get(Section, parent_id) do
          nil -> nil
          parent -> parent.path
        end
      else
        nil
      end

    path_string = Section.build_path(section_id, parent_path)

    merged_attrs = Map.merge(attrs, %{"path" => path_string, "id" => section_id})

    %Section{id: section_id}
    |> Section.changeset(merged_attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing section.
  """
  @spec update_section(Section.t(), map()) :: {:ok, Section.t()} | {:error, Ecto.Changeset.t()}
  def update_section(%Section{} = section, attrs) do
    section
    |> Section.changeset(attrs)
    |> Repo.update()
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

  Returns root sections with their `children` virtual field populated.
  """
  @spec get_course_tree(String.t()) :: [Section.t()]
  def get_course_tree(course_id) do
    sections =
      Section
      |> where([s], s.course_id == ^course_id)
      |> order_by([s], asc: s.order, asc: s.inserted_at)
      |> Repo.all()

    build_tree(sections, nil)
  end

  @spec build_tree([Section.t()], String.t() | nil) :: [Section.t()]
  defp build_tree(sections, parent_id) do
    sections
    |> Enum.filter(&(&1.parent_id == parent_id))
    |> Enum.map(fn section ->
      children = build_tree(sections, section.id)
      Map.put(section, :children, children)
    end)
  end
end
