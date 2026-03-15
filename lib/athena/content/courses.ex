defmodule Athena.Content.Courses do
  @moduledoc """
  Internal business logic for Course management.

  This module handles all database operations for courses, including
  CRUD, pagination via Flop, and safe soft deletion.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Content.Course

  @doc """
  Retrieves a paginated list of active (non-deleted) courses.

  ## Parameters
    * `params` - A map containing Flop parameters.
  """
  @spec list_courses(map()) :: {:ok, {[Course.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_courses(params \\ %{}) do
    Course
    |> where([c], is_nil(c.deleted_at))
    |> Flop.validate_and_run(params, for: Course)
  end

  @doc """
  Retrieves a single course by its ID.

  ## Returns
    * `{:ok, %Course{}}` if found and not deleted.
    * `{:error, :not_found}` otherwise.
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
end
