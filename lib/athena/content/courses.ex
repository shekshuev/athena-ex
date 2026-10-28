defmodule Athena.Content.Courses do
  @moduledoc """
  Internal business logic for Course management.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Audit
  alias Athena.Content.{Course, CourseShare, CourseLibraryBlock, LibraryBlock}
  alias Athena.Content.Workers.CourseDeepCopy
  alias Athena.Identity

  # How far either side of a competition's window it still shows on the
  # dashboard: a month before `starts_at`, a month after `ends_at`.
  @competition_dashboard_window_days 30

  @doc """
  Retrieves a paginated list of active (non-deleted) courses, scoped by user permissions.
  """
  @spec list_courses(map(), map()) ::
          {:ok, {[Course.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_courses(user, params \\ %{}) do
    Course
    |> where([c], is_nil(c.deleted_at))
    |> scope_course_reads(user)
    |> Flop.validate_and_run(params, for: Course)
  end

  @doc """
  Published competitions grouped by where "now" falls in their
  `starts_at`/`ends_at` window, as `%{upcoming: _, current: _, past: _}`.

  A competition only stays on the dashboard around the time it actually
  runs: it appears in `:upcoming` a month before `starts_at`, in `:current`
  while the window is open, and in `:past` for a month after `ends_at` -
  then it drops out of all three (the course and its leaderboard stay
  reachable by link, this only controls dashboard visibility). A
  competition with no dates set is always `:current`, which is how every
  competition behaved before the window existed.

  Deliberately unscoped by user permissions, since a competition's
  leaderboard is public to any signed-in student (see
  `AthenaWeb.LearnLive.Leaderboard`) - this is what feeds the "cheer for
  any team" cards on the student dashboard.
  """
  @spec list_competitions_by_phase() :: %{
          upcoming: [Course.t()],
          current: [Course.t()],
          past: [Course.t()]
        }
  def list_competitions_by_phase do
    now = DateTime.utc_now(:second)
    window_open = DateTime.add(now, @competition_dashboard_window_days, :day)
    window_close = DateTime.add(now, -@competition_dashboard_window_days, :day)

    Course
    |> where([c], c.type == :competition and c.status == :published and is_nil(c.deleted_at))
    |> where(
      [c],
      (is_nil(c.starts_at) or c.starts_at <= ^window_open) and
        (is_nil(c.ends_at) or c.ends_at >= ^window_close)
    )
    |> Repo.all()
    |> Enum.group_by(&competition_phase(&1, now))
    |> then(&Map.merge(%{upcoming: [], current: [], past: []}, &1))
  end

  defp competition_phase(%Course{starts_at: starts_at, ends_at: ends_at}, now) do
    cond do
      ends_at && DateTime.compare(ends_at, now) == :lt -> :past
      starts_at && DateTime.compare(starts_at, now) == :gt -> :upcoming
      true -> :current
    end
  end

  @doc """
  Retrieves a list of course IDs accessible to the user.
  Useful for cross-context authorization (e.g., in Learning context).
  """
  @spec list_accessible_course_ids(map()) :: [String.t()]
  def list_accessible_course_ids(user) do
    Course
    |> where([c], is_nil(c.deleted_at))
    |> scope_course_reads(user)
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
    |> scope_course_reads(user)
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
  Creates a new course. Automatically sets the owner_id to the creator.
  """
  @spec create_course(map(), map()) ::
          {:ok, Course.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create_course(user, attrs) do
    if Identity.can?(user, "courses.create") do
      attrs =
        attrs
        |> Map.put("owner_id", user.id)

      %Course{}
      |> Course.changeset(attrs)
      |> Repo.insert()
      |> Audit.on_ok(
        "course.created",
        &[course_id: &1.id, type: &1.type, title: &1.title, by: user.id]
      )
    else
      Audit.warning("course.create_refused", by: user.id)
      {:error, :forbidden}
    end
  end

  @doc """
  Updates an existing course.
  """
  @spec update_course(map(), Course.t(), map()) ::
          {:ok, Course.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_course(user, %Course{} = course, attrs) do
    if can_edit_course?(user, course) do
      course
      |> Course.changeset(attrs)
      |> Repo.update()
      |> Audit.on_ok(
        "course.updated",
        &[course_id: &1.id, type: &1.type, status: &1.status, by: user.id]
      )
    else
      Audit.warning("course.update_refused", course_id: course.id, by: user.id)
      {:error, :forbidden}
    end
  end

  @doc """
  Soft-deletes a course by setting the `deleted_at` timestamp.
  """
  @spec soft_delete_course(map(), Course.t()) ::
          {:ok, Course.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def soft_delete_course(user, %Course{} = course) do
    if Identity.can?(user, delete_permission(course), course) do
      course
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now(:second)})
      |> Repo.update()
      |> Audit.on_ok("course.deleted", &[course_id: &1.id, type: &1.type, by: user.id])
    else
      Audit.warning("course.delete_refused", course_id: course.id, by: user.id)
      {:error, :forbidden}
    end
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

  Scoped to one `:type` (default `:standard`), so a cohort's course picker
  never offers competitions, a team's competition picker never offers
  ordinary courses, and neither ever offers a `:library_preview` wrapper.

  ## Options

    * `:type` - the course type to search within, default `:standard`
    * `:limit` - maximum rows to return, default `10`
  """
  def search_courses_by_title(user, query, opts \\ []) do
    search_term = "%#{query}%"
    limit = Keyword.get(opts, :limit, 10)
    type = Keyword.get(opts, :type, :standard)

    Course
    |> where([c], ilike(c.title, ^search_term) and is_nil(c.deleted_at))
    |> where([c], c.type == ^type)
    |> scope_course_reads(user)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Shares a course with a specific user account (by UUID) and assigns a role.
  Updates the role if the share already exists via UPSERT.
  """
  def share_course(user, course, account_id, role \\ :reader)

  def share_course(_user, %Course{owner_id: owner_id}, account_id, _role)
      when owner_id == account_id, do: {:error, :cannot_share_with_owner}

  def share_course(user, %Course{} = course, account_id, role) do
    if can_manage_course?(user, course) do
      %CourseShare{}
      |> CourseShare.changeset(%{course_id: course.id, account_id: account_id, role: role})
      |> Repo.insert(
        on_conflict: [set: [role: role, updated_at: DateTime.utc_now(:second)]],
        conflict_target: [:course_id, :account_id]
      )
      |> case do
        {:ok, share} -> {:ok, share}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Revokes a specific user's access to a course.
  """
  def revoke_course_share(user, %Course{} = course, account_id) do
    if can_manage_course?(user, course) do
      from(cs in CourseShare, where: cs.course_id == ^course.id and cs.account_id == ^account_id)
      |> Repo.delete_all()

      {:ok, :revoked}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Toggles the public visibility of a course.
  """
  def toggle_course_public(user, %Course{} = course, is_public) when is_boolean(is_public) do
    if can_manage_course?(user, course) do
      course
      |> Ecto.Changeset.change(%{is_public: is_public})
      |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Creates a draft copy of a course (title/description/type only – no
  sections, blocks, or files yet) and enqueues `CourseDeepCopy` to deep-copy
  the rest in the background.

  The source course and any cohorts already enrolled in it are left
  completely untouched: this exists precisely so that a teacher can evolve
  a course (e.g. add new waterline-blocking tasks) for future cohorts
  without affecting cohorts who already completed the original.
  """
  @spec duplicate_course(map(), String.t(), String.t()) ::
          {:ok, Course.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def duplicate_course(user, course_id, new_title) do
    with {:ok, source_course} <- get_course(course_id),
         :ok <- check_course_write_rights(user, source_course) do
      insert_course_copy(user, source_course, new_title)
    end
  end

  @doc false
  defp insert_course_copy(user, source_course, new_title) do
    attrs = %{
      title: new_title,
      description: source_course.description,
      type: source_course.type,
      owner_id: user.id,
      source_course_id: source_course.id,
      copy_status: :copying
    }

    # Carried as a struct rather than through `cast/3`: duplicating a
    # competition that was tuned away from the defaults must not quietly
    # reset its ranking rules.
    scoring = source_course.scoring

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:course, duplicate_changeset(attrs, scoring))
    |> Ecto.Multi.run(:job, fn _repo, %{course: new_course} ->
      %{new_course_id: new_course.id, source_course_id: source_course.id}
      |> CourseDeepCopy.new()
      |> Oban.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{course: course}} -> {:ok, course}
      {:error, :course, changeset, _changes} -> {:error, changeset}
      {:error, :job, reason, _changes} -> {:error, reason}
    end
    |> Audit.on_ok(
      "course.copy_started",
      &[course_id: &1.id, source_course_id: source_course.id, by: user.id]
    )
  end

  @doc """
  Re-enqueues `CourseDeepCopy` for a course whose previous copy attempt
  failed, after clearing out whatever it left behind (see the worker's
  idempotent cleanup step).
  """
  @spec retry_course_copy(map(), Course.t()) ::
          {:ok, Course.t()} | {:error, :forbidden | :not_failed | any()}
  def retry_course_copy(user, %Course{copy_status: :failed} = course) do
    if can_edit_course?(user, course) do
      Ecto.Multi.new()
      |> Ecto.Multi.update(:course, Ecto.Changeset.change(course, copy_status: :copying))
      |> Ecto.Multi.run(:job, fn _repo, %{course: updated_course} ->
        %{new_course_id: updated_course.id, source_course_id: updated_course.source_course_id}
        |> CourseDeepCopy.new()
        |> Oban.insert()
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{course: updated_course}} -> {:ok, updated_course}
        {:error, :course, changeset, _changes} -> {:error, changeset}
        {:error, :job, reason, _changes} -> {:error, reason}
      end
    else
      {:error, :forbidden}
    end
  end

  def retry_course_copy(_user, %Course{}), do: {:error, :not_failed}

  @doc false
  defp duplicate_changeset(attrs, scoring) do
    %Course{scoring: scoring}
    |> Ecto.Changeset.cast(attrs, [
      :title,
      :description,
      :type,
      :owner_id,
      :source_course_id,
      :copy_status
    ])
    |> Ecto.Changeset.put_change(:status, :draft)
    |> Ecto.Changeset.validate_required([:title, :type, :owner_id, :source_course_id])
    |> Ecto.Changeset.validate_length(:title, min: 3, max: 255)
    |> Ecto.Changeset.unique_constraint(:title, name: :courses_title_index)
  end

  @doc """
  Returns a list of maps %{account_id: id, role: role} that this course is shared with.
  """
  def list_course_shares(%Course{} = course) do
    Repo.all(
      from cs in CourseShare,
        where: cs.course_id == ^course.id,
        select: %{account_id: cs.account_id, role: cs.role}
    )
  end

  @doc """
  Checks whether the user can edit the course (owner or has the writer role).
  """
  def can_edit_course?(user, course) do
    permission = update_permission(course)

    if Identity.can?(user, permission, course) do
      true
    else
      if Identity.can?(user, permission) do
        Repo.exists?(
          from cs in CourseShare,
            where: cs.course_id == ^course.id and cs.account_id == ^user.id and cs.role == :writer
        )
      else
        false
      end
    end
  end

  @doc false
  defp can_manage_course?(user, course) do
    Identity.can?(user, update_permission(course), course)
  end

  @doc false
  def read_permission(%Course{type: :competition}), do: "competitions.read"
  def read_permission(%Course{}), do: "courses.read"

  @doc false
  def update_permission(%Course{type: :competition}), do: "competitions.update"
  def update_permission(%Course{}), do: "courses.update"

  @doc false
  def delete_permission(%Course{type: :competition}), do: "competitions.delete"
  def delete_permission(%Course{}), do: "courses.delete"

  @doc false
  # Regular courses and competitions are gated by separate permissions
  # ("courses.read"/"competitions.read"), each with its own independent
  # "own_only" policy - a user can hold either, both, or neither, so the
  # visible set is the union of whichever per-type conditions actually
  # apply, not a single permission check for the whole query.
  defp scope_course_reads(query, user) do
    conditions =
      [{"courses.read", :standard}, {"competitions.read", :competition}]
      |> Enum.map(fn {permission, type} -> course_type_condition(user, permission, type) end)
      |> Enum.reject(&is_nil/1)

    case conditions do
      [] -> from c in query, where: false
      [condition] -> from c in query, where: ^condition
      [condition_1, condition_2] -> from c in query, where: ^dynamic(^condition_1 or ^condition_2)
    end
  end

  defp course_type_condition(user, permission, type) do
    if Identity.can?(user, permission) do
      policies = Map.get(user.role.policies || %{}, permission, [])

      if "own_only" in policies do
        shared_course_ids =
          from cs in CourseShare,
            where: cs.account_id == ^user.id,
            select: cs.course_id

        dynamic(
          [c],
          c.type == ^type and
            (c.owner_id == ^user.id or c.is_public == true or c.id in subquery(shared_course_ids))
        )
      else
        dynamic([c], c.type == ^type)
      end
    end
  end

  @doc """
  Pins a library block to a course workspace (Course Bank).
  Requires write permissions on the course.
  """
  @spec pin_library_block(map(), String.t(), String.t()) ::
          {:ok, CourseLibraryBlock.t()} | {:error, Ecto.Changeset.t() | atom()}
  def pin_library_block(user, course_id, library_block_id) do
    with {:ok, course} <- get_course(course_id),
         :ok <- check_course_write_rights(user, course) do
      %CourseLibraryBlock{}
      |> CourseLibraryBlock.changeset(%{course_id: course_id, library_block_id: library_block_id})
      |> Repo.insert()
    end
  end

  @doc """
  Unpins a library block from a course workspace.
  """
  @spec unpin_library_block(map(), String.t(), String.t()) ::
          {:ok, {integer(), nil}} | {:error, atom()}
  def unpin_library_block(user, course_id, library_block_id) do
    with {:ok, course} <- get_course(course_id),
         :ok <- check_course_write_rights(user, course) do
      query =
        from(clb in CourseLibraryBlock,
          where: clb.course_id == ^course_id and clb.library_block_id == ^library_block_id
        )

      {:ok, Repo.delete_all(query)}
    end
  end

  @doc """
  Lists all library blocks pinned to a specific course.
  """
  @spec list_course_workspace_blocks(map(), String.t()) :: [LibraryBlock.t()]
  def list_course_workspace_blocks(user, course_id) do
    with {:ok, _course} <- get_course(user, course_id) do
      CourseLibraryBlock
      |> where(course_id: ^course_id)
      |> join(:inner, [clb], lb in LibraryBlock, on: clb.library_block_id == lb.id)
      |> select([clb, lb], lb)
      |> Repo.all()
    end
  end

  @doc false
  defp check_course_write_rights(user, course) do
    if can_edit_course?(user, course), do: :ok, else: {:error, :forbidden}
  end
end
