defmodule Athena.Content.Courses do
  @moduledoc """
  Internal business logic for Course management.

  This module handles all database operations for courses, including
  CRUD, pagination via Flop, and safe soft deletion.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Content.Course
  alias Athena.Identity

  @doc """
  Retrieves a paginated list of active (non-deleted) courses, scoped by user permissions.
  """
  @spec list_courses(map(), map()) ::
          {:ok, {[Course.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_courses(user, params \\ %{}) do
    Course
    |> where([c], is_nil(c.deleted_at))
    |> Identity.scope_query(user, "courses.read")
    |> Flop.validate_and_run(params, for: Course)
  end

  @doc """
  Retrieves a list of course IDs accessible to the user.
  Useful for cross-context authorization (e.g., in Learning context).
  """
  @spec list_accessible_course_ids(map()) :: [String.t()]
  def list_accessible_course_ids(user) do
    Course
    |> where([c], is_nil(c.deleted_at))
    |> Identity.scope_query(user, "courses.read")
    |> select([c], c.id)
    |> Repo.all()
  end

  @doc """
  Retrieves a single course by its ID, scoped by user permissions.
  """
  @spec get_course(map(), String.t()) :: {:ok, Course.t()} | {:error, :not_found}
  def get_course(user, id) do
    Course
    |> where([c], c.id == ^id and is_nil(c.deleted_at))
    |> Identity.scope_query(user, "courses.read")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      course -> {:ok, course}
    end
  end

  @doc """
  Retrieves a single course by its ID without ACL policies.
  Used for students (where Learning.has_access? already validated access) and internal logic.
  """
  @spec get_course(String.t()) :: {:ok, Course.t()} | {:error, :not_found}
  def get_course(id) do
    case Repo.get(Course, id) do
      %Course{deleted_at: nil} = course -> {:ok, course}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Creates a new course.
  """
  @spec create_course(map()) :: {:ok, Course.t()} | {:error, Ecto.Changeset.t()}
  def create_course(attrs) do
    %Course{}
    |> Course.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing course.
  """
  @spec update_course(Course.t(), map()) :: {:ok, Course.t()} | {:error, Ecto.Changeset.t()}
  def update_course(%Course{} = course, attrs) do
    course
    |> Course.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Soft-deletes a course by setting the `deleted_at` timestamp.
  """
  @spec soft_delete_course(Course.t()) :: {:ok, Course.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete_course(%Course{} = course) do
    course
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  @doc """
  Returns a map of `%{course_id => Course}` for bulk enrichment across contexts.
  Excludes soft-deleted courses.
  """
  @spec get_courses_map([String.t()]) :: %{String.t() => Course.t()}
  def get_courses_map(ids) when is_list(ids) do
    Course
    |> where([c], c.id in ^ids and is_nil(c.deleted_at))
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Searches active courses by title for autocomplete components.
  """
  def search_courses_by_title(query, limit \\ 10) do
    search_term = "%#{query}%"

    Course
    |> where([c], ilike(c.title, ^search_term) and is_nil(c.deleted_at))
    |> limit(^limit)
    |> Repo.all()
  end
end
