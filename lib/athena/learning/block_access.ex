defmodule Athena.Learning.BlockAccess do
  @moduledoc "Shared block progression rules for the player and search."

  alias Athena.{Content, Learning}
  alias Athena.Learning.TestRunSession
  alias Athena.Repo
  import Ecto.Query

  @doc """
  Resolves an interactive block against current enrollment, policy and progression.

  Preview exceptions come only from an active persisted test-run session for
  this account and course, never from event parameters or caller-supplied flags.
  The snapshot is read-only: denied requests must not heal or award progress.
  """
  def fetch_interactive_block(user, course_id, block_id) do
    with {:ok, course_id} <- Ecto.UUID.cast(course_id),
         {:ok, block_id} <- Ecto.UUID.cast(block_id),
         {:ok, _course} <- Content.get_course(course_id),
         opts <- preview_options(user.id, course_id),
         true <- opts != [] or Learning.has_access?(user.id, course_id),
         true <- Map.has_key?(course_block_access(user, course_id, opts), block_id),
         false <- Content.InteractionPolicy.block_readonly?(block_id),
         {:ok, block} <- Content.get_block(block_id) do
      {_cohort, _cohort_id, team_id} = Learning.resolve_course_cohort(user.id, course_id)
      {:ok, block, team_id}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp preview_options(account_id, course_id) do
    active? =
      Repo.exists?(
        from s in TestRunSession,
          where:
            s.ephemeral_account_id == ^account_id and s.course_id == ^course_id and
              s.status == :active and s.expires_at > ^DateTime.utc_now()
      )

    if active?, do: [ignore_schedule?: true, ignore_visibility?: true], else: []
  end

  @doc "Read-only media access for enrolled students or a persisted instructor preview."
  def media_block_access(user, course_id) do
    opts = preview_options(user.id, course_id)

    if opts != [] or Learning.has_access?(user.id, course_id),
      do: course_block_access(user, course_id, opts),
      else: %{}
  end

  @doc """
  Returns a read-only snapshot of currently accessible block headers in a course.

  Course enrollment must be checked by the caller. Loads metadata once per
  course, never content or search text, and shares progression with the player.
  """
  def course_block_access(user, course_id, policy_opts \\ []) do
    {_cohort, cohort_id, team_id} = Learning.resolve_course_cohort(user.id, course_id)
    overrides = Learning.get_student_overrides(user.id, course_id, cohort_id)
    lessons = Content.list_linear_lessons(course_id, user, overrides, policy_opts)
    headers = Content.list_block_headers_by_section_ids(Enum.map(lessons, & &1.id))

    completed =
      Learning.effective_completed_block_ids(headers, user, team_id, heal_progress?: false)

    opts =
      policy_opts ++ [heal_progress?: false, block_headers: headers, completed_ids: completed]

    accessible =
      Learning.accessible_section_ids(user, course_id, lessons, overrides, team_id, opts)

    by_section = Enum.group_by(headers, & &1.section_id)

    lessons
    |> Enum.filter(&(&1.id in accessible))
    |> Enum.flat_map(fn section ->
      by_section
      |> Map.get(section.id, [])
      |> policy_visible_blocks(section, user, overrides, policy_opts)
      |> visible_blocks(completed)
    end)
    |> Map.new(&{&1.id, &1})
  end

  @doc "Filters block headers or full blocks through the same policy as the player."
  def policy_visible_blocks(blocks, section, user, overrides, opts) do
    opts = Keyword.put(opts, :sections, %{section.id => section})

    blocks
    |> Enum.filter(&Athena.Content.can_view?(user, &1, overrides, opts))
    |> Enum.sort_by(& &1.order)
  end

  @doc "Applies the player waterline to ordered, policy-visible blocks."
  def visible_blocks(blocks, completed_ids) do
    completed_ids = MapSet.new(completed_ids)

    {visible, _blocked?} =
      Enum.reduce(blocks, {[], false}, fn block, {acc, blocked?} ->
        reset? = block.access_rules && block.access_rules.reset_waterline
        current_blocked? = if reset?, do: false, else: blocked?

        is_completed = MapSet.member?(completed_ids, block.id)

        if current_blocked? do
          {acc, true}
        else
          new_acc = [block | acc]

          next_blocked? =
            block.completion_rule && block.completion_rule.type != :none && not is_completed

          {new_acc, next_blocked?}
        end
      end)

    Enum.reverse(visible)
  end
end
