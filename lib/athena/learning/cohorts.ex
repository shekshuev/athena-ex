defmodule Athena.Learning.Cohorts do
  @moduledoc """
  Internal business logic for Cohort management.

  Handles CRUD operations for `Cohort` and manages the many-to-many
  relationships with `Instructor` and the one-to-many relationships
  with `CohortMembership` (students).
  """

  import Ecto.Query
  alias Athena.Repo
  require Logger

  alias Athena.Learning.{
    Cohort,
    Instructor,
    CohortMembership,
    CohortInstructor,
    Instructors,
    Enrollment
  }

  alias Athena.{Identity, Content, Messaging}

  @doc """
  Retrieves a paginated list of cohorts, scoped by user permissions.
  """
  @spec list_cohorts(map(), map()) ::
          {:ok, {[Cohort.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_cohorts(user, params \\ %{}) do
    base_query =
      from(c in Cohort)
      |> scope_cohort_reads(user)

    case Flop.validate_and_run(base_query, params, for: Cohort) do
      {:ok, {cohorts, meta}} ->
        cohorts = Repo.preload(cohorts, :instructors)
        {:ok, {enrich_cohorts(cohorts), meta}}

      error ->
        error
    end
  end

  @doc """
  Retrieves a single cohort safely.
  """
  def get_cohort(user, id) do
    Cohort
    |> where([c], c.id == ^id)
    |> scope_cohort_reads(user)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      cohort -> {:ok, enrich_cohorts(Repo.preload(cohort, :instructors))}
    end
  end

  @doc """
  The cohorts enrolled in a course - for the cross-cohort comparison
  screen's cohort picker. A cohort-level enrollment is one `Enrollment` row
  with both `course_id` and `cohort_id` set (as opposed to an individual
  student enrollment, which has `cohort_id: nil`), so this is exactly the
  set of cohorts an enrollment join into `course_id` produces, filtered
  through the same `scope_cohort_reads/2` ACL `list_cohorts/2`/`get_cohort/2`
  already apply - a teacher only sees cohorts they're otherwise allowed to
  read.
  """
  @spec list_cohorts_for_course(map(), binary()) :: [Cohort.t()]
  def list_cohorts_for_course(user, course_id) do
    cohort_ids_query =
      from e in Enrollment,
        where: e.course_id == ^course_id and not is_nil(e.cohort_id),
        select: e.cohort_id,
        distinct: true

    Cohort
    |> where([c], c.id in subquery(cohort_ids_query))
    |> order_by([c], asc: c.name)
    |> scope_cohort_reads(user)
    |> Repo.all()
    |> Repo.preload(:instructors)
    |> enrich_cohorts()
  end

  @doc """
  Creates a new cohort.

  Optionally accepts a list of instructor IDs in `instructor_ids` to assign them immediately.
  """
  @spec create_cohort(map(), map()) ::
          {:ok, Cohort.t()} | {:error, Ecto.Changeset.t()} | {:error, :forbidden}
  def create_cohort(user, attrs) do
    if Identity.can?(user, "cohorts.create") do
      do_create_cohort(user, attrs)
    else
      {:error, :forbidden}
    end
  end

  defp do_create_cohort(user, attrs) do
    result =
      %Cohort{owner_id: user.id}
      |> Repo.preload(:instructors)
      |> Cohort.changeset(attrs)
      |> put_instructors(attrs["instructor_ids"] || attrs[:instructor_ids])
      |> Repo.insert()

    case result do
      {:ok, cohort} ->
        safe_sync(fn -> sync_new_cohort_participants(cohort) end)
        result

      error ->
        error
    end
  end

  defp sync_new_cohort_participants(cohort) do
    {:ok, _conversation} = Messaging.ensure_cohort_conversation(cohort)

    Enum.each(
      cohort.instructors,
      &Messaging.add_cohort_participant(cohort.id, &1.owner_id)
    )
  end

  @doc """
  Updates an existing cohort.

  If `instructor_ids` is provided, it completely replaces the current list of instructors.
  """
  @spec update_cohort(map(), Cohort.t(), map()) ::
          {:ok, Cohort.t()} | {:error, Ecto.Changeset.t()} | {:error, :forbidden}
  def update_cohort(user, %Cohort{} = cohort, attrs) do
    if Identity.can?(user, "cohorts.update", cohort) do
      do_update_cohort(cohort, attrs)
    else
      {:error, :forbidden}
    end
  end

  defp do_update_cohort(cohort, attrs) do
    preloaded_cohort = Repo.preload(cohort, :instructors)
    old_instructor_account_ids = Enum.map(preloaded_cohort.instructors, & &1.owner_id)

    result =
      preloaded_cohort
      |> Cohort.changeset(attrs)
      |> put_instructors(attrs["instructor_ids"] || attrs[:instructor_ids])
      |> Repo.update()

    case result do
      {:ok, updated} ->
        safe_sync(fn ->
          sync_cohort_instructor_participants(updated, old_instructor_account_ids)
        end)

        result

      error ->
        error
    end
  end

  @doc false
  defp sync_cohort_instructor_participants(cohort, old_instructor_account_ids) do
    new_ids = cohort.instructors |> Enum.map(& &1.owner_id) |> MapSet.new()
    old_ids = MapSet.new(old_instructor_account_ids)

    new_ids
    |> MapSet.difference(old_ids)
    |> Enum.each(&Messaging.add_cohort_participant(cohort.id, &1))

    old_ids
    |> MapSet.difference(new_ids)
    |> Enum.each(&Messaging.remove_cohort_participant(cohort.id, &1))
  end

  @doc false
  defp safe_sync(fun) do
    fun.()
  rescue
    e ->
      Logger.error(
        "[Cohorts] messenger sync failed: " <> Exception.format(:error, e, __STACKTRACE__)
      )
  end

  @doc """
  Deletes a cohort.
  Only true owners or global admins can delete.
  """
  @spec delete_cohort(map(), Cohort.t()) :: {:ok, Cohort.t()} | {:error, Ecto.Changeset.t()}
  def delete_cohort(user, %Cohort{} = cohort) do
    if Identity.can?(user, "cohorts.delete", cohort) do
      Repo.delete(cohort)
    else
      {:error, :forbidden}
    end
  end

  @doc """
  (2b) Can a user add students, assign courses, and change overrides?
  Requires: "cohorts.update" permission (either owner or co-instructor).
  """
  def can_manage_cohort_processes?(user, cohort) do
    if Identity.can?(user, "cohorts.update") do
      if Identity.can?(user, "cohorts.update", cohort) do
        true
      else
        co_instructor?(user, cohort)
      end
    else
      false
    end
  end

  @doc """
  (2a) Can a user simply view the cohort and schedule?
  Requires: "cohorts.read" permission (either owner or co-instructor).
  """
  def can_view_cohort_processes?(user, cohort) do
    if Identity.can?(user, "cohorts.read") do
      if Identity.can?(user, "cohorts.read", cohort) do
        true
      else
        co_instructor?(user, cohort)
      end
    else
      false
    end
  end

  @doc false
  defp co_instructor?(user, cohort) do
    query =
      from ci in CohortInstructor,
        join: i in Instructor,
        on: ci.instructor_id == i.id,
        where: ci.cohort_id == ^cohort.id and i.owner_id == ^user.id

    Repo.exists?(query)
  end

  @doc false
  defp scope_cohort_reads(query, user) do
    if Identity.can?(user, "cohorts.read") do
      policies = Map.get(user.role.policies || %{}, "cohorts.read", [])

      if "own_only" in policies do
        instructor_cohort_ids =
          from ci in CohortInstructor,
            join: i in Instructor,
            on: ci.instructor_id == i.id,
            where: i.owner_id == ^user.id,
            select: ci.cohort_id

        from c in query,
          where: c.owner_id == ^user.id or c.id in subquery(instructor_cohort_ids)
      else
        query
      end
    else
      from c in query, where: false
    end
  end

  @doc false
  defp put_instructors(changeset, nil), do: changeset

  defp put_instructors(changeset, ids) when is_list(ids) do
    clean_ids = Enum.reject(ids, &(&1 == ""))
    instructors = Repo.all(from i in Instructor, where: i.id in ^clean_ids)
    Ecto.Changeset.put_assoc(changeset, :instructors, instructors)
  end

  @doc """
  Retrieves a paginated list of students enrolled in a specific cohort.
  """
  @spec list_cohort_memberships(String.t(), map()) ::
          {:ok, {[CohortMembership.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_cohort_memberships(cohort_id, params \\ %{}) do
    case CohortMembership
         |> where(cohort_id: ^cohort_id)
         |> Flop.validate_and_run(params, for: CohortMembership) do
      {:ok, {memberships, meta}} ->
        {:ok, {enrich_memberships_with_accounts(memberships), meta}}

      error ->
        error
    end
  end

  @doc """
  Gets a specific cohort membership by ID.
  """
  @spec get_cohort_membership!(String.t()) :: CohortMembership.t()
  def get_cohort_membership!(id) do
    Repo.get!(CohortMembership, id)
    |> enrich_memberships_with_accounts()
  end

  # вверху модуля, где алиасы
  alias Athena.Learning.{
    Cohort,
    Instructor,
    CohortMembership,
    CohortInstructor,
    Instructors,
    Enrollment
  }

  alias Athena.{Identity, Content, Messaging}

  @doc """
  Adds a student account to a cohort.

  Prevents enrollment if the student already has access to any course
  that this cohort is currently enrolled in (via another cohort or individual enrollment).
  """
  @spec add_student_to_cohort(map(), String.t(), String.t()) ::
          {:ok, CohortMembership.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, String.t()}
          | {:error, :forbidden}
  def add_student_to_cohort(user, cohort_id, account_id) do
    cohort = Repo.get!(Cohort, cohort_id)

    with :ok <- check_cohort_manage_rights(user, cohort),
         :ok <- validate_no_student_overlap(cohort_id, account_id) do
      finish_add_student(cohort_id, account_id)
    end
  end

  @doc false
  defp finish_add_student(cohort_id, account_id) do
    case do_insert_membership(cohort_id, account_id) do
      {:ok, _membership} = result ->
        safe_sync(fn -> Messaging.add_cohort_participant(cohort_id, account_id) end)
        result

      error ->
        error
    end
  end

  @doc false
  defp check_cohort_manage_rights(user, cohort) do
    if can_manage_cohort_processes?(user, cohort), do: :ok, else: {:error, :forbidden}
  end

  @doc false
  defp validate_no_student_overlap(cohort_id, account_id) do
    enrolled_course_ids =
      from(e in Enrollment,
        where: e.cohort_id == ^cohort_id and e.status != :dropped,
        select: e.course_id
      )
      |> Repo.all()

    if enrolled_course_ids == [] do
      :ok
    else
      overlapping_course_ids =
        find_overlapping_courses(account_id, enrolled_course_ids, cohort_id)

      check_overlapping_results(overlapping_course_ids)
    end
  end

  @doc false
  defp check_overlapping_results([]), do: :ok

  defp check_overlapping_results(overlapping_course_ids) do
    course_titles =
      from(c in Content.Course,
        where: c.id in ^overlapping_course_ids,
        select: c.title
      )
      |> Repo.all()
      |> Enum.join(", ")

    {:error,
     "Cannot add student: they already have access to course(s): #{course_titles} through other enrollment(s)"}
  end

  @doc false
  defp find_overlapping_courses(account_id, course_ids, current_cohort_id) do
    individual_courses =
      from(e in Enrollment,
        where:
          e.account_id == ^account_id and
            e.course_id in ^course_ids and
            e.status != :dropped,
        select: e.course_id
      )
      |> Repo.all()

    other_cohort_courses =
      from(cm in CohortMembership,
        join: e in Enrollment,
        on: e.cohort_id == cm.cohort_id,
        where:
          cm.account_id == ^account_id and
            cm.cohort_id != ^current_cohort_id and
            e.course_id in ^course_ids and
            e.status != :dropped,
        select: e.course_id,
        distinct: true
      )
      |> Repo.all()

    Enum.uniq(individual_courses ++ other_cohort_courses)
  end

  @doc false
  defp do_insert_membership(cohort_id, account_id) do
    %CohortMembership{}
    |> CohortMembership.changeset(%{cohort_id: cohort_id, account_id: account_id})
    |> Repo.insert()
  end

  @doc """
  Removes a student account from a cohort.
  """
  @spec remove_student_from_cohort(map(), CohortMembership.t()) ::
          {:ok, CohortMembership.t()} | {:error, Ecto.Changeset.t()}
  def remove_student_from_cohort(user, %CohortMembership{} = membership) do
    cohort = Repo.get!(Cohort, membership.cohort_id)

    if can_manage_cohort_processes?(user, cohort) do
      case Repo.delete(membership) do
        {:ok, deleted} = result ->
          safe_sync(fn ->
            Messaging.remove_cohort_participant(deleted.cohort_id, deleted.account_id)
          end)

          result

        error ->
          error
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Returns a map of `%{cohort_id => Cohort}` for bulk enrichment across
  contexts. Unscoped by design (mirrors `Identity.get_accounts_map/1`) — a
  cohort chat participant must see the cohort's name regardless of whether
  they hold the `"cohorts.read"` permission.
  """
  @spec get_cohorts_map([String.t()]) :: %{String.t() => Cohort.t()}
  def get_cohorts_map(ids) when is_list(ids) do
    Cohort
    |> where([c], c.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Retrieves a simplified list of cohorts for dropdown menus.
  Returns `[{"Cohort Name", "cohort_id"}, ...]`.
  """
  def get_cohort_options(user) do
    from(c in Cohort)
    |> scope_cohort_reads(user)
    |> select([c], {c.name, c.id})
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc false
  defp enrich_memberships_with_accounts(%CohortMembership{} = membership) do
    [enriched] = enrich_memberships_with_accounts([membership])
    enriched
  end

  defp enrich_memberships_with_accounts([]), do: []

  defp enrich_memberships_with_accounts(memberships) do
    account_ids = Enum.map(memberships, & &1.account_id) |> Enum.uniq()
    accounts_map = Identity.get_accounts_map(account_ids)

    Enum.map(memberships, fn membership ->
      %{membership | account: Map.get(accounts_map, membership.account_id)}
    end)
  end

  @doc false
  defp enrich_cohorts(%Cohort{} = cohort) do
    %{cohort | instructors: Instructors.enrich_with_accounts(cohort.instructors)}
  end

  defp enrich_cohorts(cohorts) when is_list(cohorts) do
    Enum.map(cohorts, fn cohort ->
      %{cohort | instructors: Instructors.enrich_with_accounts(cohort.instructors)}
    end)
  end
end
