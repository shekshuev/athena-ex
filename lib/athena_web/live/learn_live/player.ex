defmodule AthenaWeb.LearnLive.Player do
  @moduledoc """
  The core learning interface: Progressive Disclosure Player.

  Enforces strict Waterfall progression through course content. Handles
  the rendering of various block types (text, media, code) and manages
  interactive progression gates (e.g., "Require Button Click", "Pass Auto-Grade").

  Features real-time synchronization via PubSub to immediately react to
  instructor changes (like hiding a section or locking it with a timer)
  and safely boot the student back to the syllabus if access is revoked.
  """
  use AthenaWeb, :live_view

  on_mount {AthenaWeb.Hooks.Auth, :test_run}

  alias Athena.Content
  alias Athena.Content.Policy
  alias Athena.Engagement
  alias Athena.Execution
  alias Athena.Identity
  alias Athena.Learning

  import AthenaWeb.LeaderboardComponents
  alias Athena.Surveys
  alias Athena.Surveys.Flow
  alias AthenaWeb.LearnLive.EngagementSignals

  import AthenaWeb.SurveyComponents, only: [question: 1]
  import AthenaWeb.BlockComponents

  @doc """
  Initializes the player, checks course access, and validates that the student
  has reached the requested section. Redirects to a safe zone if access is blocked.
  """
  @spec mount(map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  # Nested `live_render/3` mounts (the builder's "test run" modal) never go
  # through the router, so `params` arrives as the literal atom
  # `:not_mounted_at_router` instead of a map – `course_id`/`section_id` come
  # from the test-run session itself (stashed onto the socket by
  # `AthenaWeb.Hooks.Auth`'s `:test_run` on_mount hook) rather than the URL.
  def mount(:not_mounted_at_router, _session, %{assigns: %{test_run: true}} = socket) do
    mount_player(
      %{"section_id" => socket.assigns.test_run_section_id},
      socket.assigns.test_run_course_id,
      socket
    )
  end

  def mount(%{"id" => course_id} = params, _session, socket) do
    mount_player(params, course_id, socket)
  end

  # The static (disconnected) render only shows a skeleton: everything below
  # costs dozens of queries, and running it twice per page view (static +
  # connected mount) doubled the player's database load for no visible gain.
  @doc false
  defp mount_player(_params, _course_id, socket) when is_nil(socket.transport_pid) do
    {:ok, assign(socket, loading: true, test_run: !!socket.assigns[:test_run])}
  end

  defp mount_player(params, course_id, socket) do
    user = socket.assigns.current_user
    test_run? = !!socket.assigns[:test_run]
    socket = assign(socket, :test_run, test_run?)
    opts = [ignore_schedule?: test_run?, ignore_visibility?: test_run?]

    with true <- test_run? || Learning.has_access?(user.id, course_id),
         {:ok, course} <- Content.get_course(course_id) do
      {cohort, cohort_id, team_id} = Learning.resolve_course_cohort(user.id, course_id)

      if connected?(socket), do: subscribe_to_topics(course, team_id, user.id)

      overrides = Learning.get_student_overrides(user.id, course_id, cohort_id)
      outline = Content.course_outline(course_id, user, overrides, opts)
      linear_lessons = outline.linear_lessons
      block_counts = outline.block_counts

      accessible_ids =
        Learning.accessible_section_ids(
          user,
          course_id,
          linear_lessons,
          overrides,
          team_id,
          opts
        )

      first_lesson = List.first(linear_lessons)
      first_lesson_id = if first_lesson, do: first_lesson.id, else: nil
      section_id = params["section_id"] || first_lesson_id

      if section_id in accessible_ids do
        ctx = %{
          user: user,
          overrides: overrides,
          cohort_id: cohort_id,
          team_id: team_id,
          block_counts: block_counts,
          engagement_session_id: Ecto.UUID.generate(),
          nudges_enabled: !!(cohort && cohort.nudges_enabled),
          opts: opts,
          outline: outline
        }

        setup_player_state(
          socket,
          course,
          section_id,
          linear_lessons,
          accessible_ids,
          ctx,
          params["block"]
        )
      else
        {:ok,
         socket
         |> put_flash(:error, gettext("You must complete previous lessons first."))
         |> push_navigate(to: ~p"/learn/courses/#{course_id}")}
      end
    else
      _ ->
        {:ok,
         push_navigate(socket |> put_flash(:error, gettext("Access denied.")), to: ~p"/learn")}
    end
  end

  @doc false
  defp subscribe_to_topics(course, cohort_id, user_id) do
    Phoenix.PubSub.subscribe(Athena.PubSub, "course_content:#{course.id}")

    Phoenix.PubSub.subscribe(Athena.PubSub, "media_upload:#{user_id}")

    if cohort_id do
      Phoenix.PubSub.subscribe(Athena.PubSub, "team_progress:#{cohort_id}")
    else
      Phoenix.PubSub.subscribe(Athena.PubSub, "user_progress:#{user_id}")
    end

    # Only a competition has a board, and only then does the player carry
    # one - a standard course subscribes to nothing and holds no rows.
    if course.type == :competition do
      Phoenix.PubSub.subscribe(Athena.PubSub, "leaderboard:#{course.id}")
    end
  end

  @doc false
  defp setup_player_state(
         socket,
         course,
         section_id,
         linear_lessons,
         accessible_ids,
         ctx,
         scroll_to_block_id
       ) do
    section = Content.get_section(section_id) |> elem(1)
    blocks = visible_section_blocks(section, ctx.user, ctx.overrides, ctx.opts)

    completed_ids = Learning.completed_block_ids(ctx.user.id, section_id, ctx.team_id)
    tree = ctx.outline.tree

    current_index = Enum.find_index(linear_lessons, fn s -> s.id == section_id end)

    prev_section = if current_index > 0, do: Enum.at(linear_lessons, current_index - 1), else: nil
    next_section = Enum.at(linear_lessons, current_index + 1)
    next_accessible? = next_section != nil and next_section.id in accessible_ids

    submissions =
      Learning.get_latest_submissions(ctx.user.id, Enum.map(blocks, & &1.id), ctx.team_id)

    feedback_map =
      Learning.get_feedback_map(ctx.user.id, Enum.map(blocks, & &1.id), ctx.team_id)

    drafts = load_drafts(ctx.user.id, Enum.map(blocks, & &1.id), ctx.team_id)

    pending_file_urls = load_pending_file_urls(blocks, drafts)

    if connected?(socket) do
      subscribe_to_block_topics(blocks, ctx.user.id, ctx.team_id)
    end

    socket =
      socket
      |> assign(:page_title, section.title)
      |> assign(:course, course)
      |> assign(:engagement_session_id, ctx.engagement_session_id)
      |> assign(:nudges_enabled, ctx.nudges_enabled)
      |> assign(:engagement_pending_enters, %{})
      |> assign(:engagement_scroll_progress, %{})
      |> assign(:engagement_video_forward_skip, %{})
      |> assign(:engagement_answered_blocks, MapSet.new())
      |> assign(:nudged_block_ids, MapSet.new())
      |> assign(:cohort_id, ctx.cohort_id)
      |> assign(:team_id, ctx.team_id)
      |> assign(:tree, tree)
      |> assign(:linear_lessons, linear_lessons)
      |> assign(:section, section)
      |> assign(:blocks, blocks)
      |> assign(:completed_ids, completed_ids)
      |> assign(:prev_section_id, if(prev_section, do: prev_section.id, else: nil))
      |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
      |> assign(:course_map_open, false)
      |> assign(:leaderboard_open, false)
      |> assign(:leaderboard, load_leaderboard(course))
      |> assign(:visible_blocks, calc_visible_blocks(blocks, completed_ids))
      |> assign(:submissions, submissions)
      |> assign(
        :exam_holders,
        load_exam_holders(blocks, submissions, ctx.user.id, ctx.team_id)
      )
      |> assign(:feedback_map, feedback_map)
      |> assign(:drafts, drafts)
      |> assign(:overrides, ctx.overrides)
      |> assign(:block_counts, ctx.block_counts)
      |> assign(:show_media_modal, false)
      |> assign(:active_upload_block_id, nil)
      |> assign(:upload_type, nil)
      |> assign(:pending_file_urls, pending_file_urls)
      |> assign(:refresh_pending, nil)
      |> assign(:unlock_timer, nil)
      |> assign(:schedule_times, load_schedule_times(ctx.outline.all_linear_lessons))
      |> assign(:survey_block_ids, survey_block_ids(blocks))
      |> assign(:survey_state, load_survey_state(blocks, ctx.user))
      |> maybe_push_scroll_to_block(scroll_to_block_id)

    {:ok, schedule_next_unlock(socket)}
  end

  # -- survey rendering -----------------------------------------------------

  attr :block, :map, required: true
  attr :state, :map, default: nil
  attr :completed?, :boolean, default: false

  defp survey_block(%{state: nil} = assigns), do: survey_notice(assigns)

  defp survey_block(%{state: %{status: :missing}} = assigns), do: survey_notice(assigns)

  defp survey_block(%{state: %{status: :unavailable}} = assigns) do
    ~H"""
    <.survey_shell title={gettext("Survey not open yet")}>
      <p class="text-sm text-base-content/60">
        {gettext("Your instructor has not published this survey yet.")}
      </p>
    </.survey_shell>
    """
  end

  defp survey_block(%{state: %{status: :closed}} = assigns) do
    ~H"""
    <.survey_shell title={@state.survey.title}>
      <p class="text-sm text-base-content/60">
        {gettext("This survey is closed and no longer accepts answers.")}
      </p>
    </.survey_shell>
    """
  end

  defp survey_block(%{state: %{status: :completed}} = assigns) do
    ~H"""
    <.survey_shell title={@state.survey.title}>
      <div class="flex items-start gap-3">
        <.icon name="hero-check-circle" class="size-6 shrink-0 text-success" />
        <div class="text-sm">
          <p class="font-bold">{gettext("Thank you, your answers are in.")}</p>
          <p class="mt-1 text-base-content/60">
            {gettext("Answers from your group are reported together, never one by one.")}
          </p>
        </div>
      </div>
    </.survey_shell>
    """
  end

  # Reached the end of the path: nothing left to answer, so the only thing to
  # do is send it. Submitting is a separate step from answering the last
  # question so that nobody submits by accident on a branch they did not mean
  # to take.
  defp survey_block(%{state: %{current: nil}} = assigns) do
    ~H"""
    <.survey_shell title={@state.survey.title}>
      <p class="mb-5 text-sm text-base-content/60">
        {gettext("That is everything. Send your answers when you are ready.")}
      </p>
      <div class="flex flex-wrap gap-2">
        <.button
          :if={@state.history != []}
          variant="ghost"
          size="sm"
          phx-click="survey_back"
          phx-value-block_id={@block.id}
          id={"survey-back-#{@block.id}"}
        >
          {gettext("Back")}
        </.button>
        <.button
          variant="primary"
          size="sm"
          phx-click="survey_submit"
          phx-value-block_id={@block.id}
          id={"survey-submit-#{@block.id}"}
        >
          {gettext("Send my answers")}
        </.button>
      </div>
    </.survey_shell>
    """
  end

  defp survey_block(assigns) do
    ~H"""
    <.survey_shell title={@block.content["title_override"] || @state.survey.title}>
      <div
        :if={@state.survey.settings.show_progress}
        class="mb-5 flex items-center gap-3 text-xs text-base-content/50"
      >
        <%!-- Counts the path this student is actually on, not the whole
              survey: with branching the two differ, and the larger number
              would be a lie. --%>
        <progress
          class="progress progress-primary h-1.5 flex-1"
          value={survey_answered_count(@state)}
          max={survey_path_length(@state)}
        >
        </progress>
        <span class="tabular-nums">
          {gettext("%{answered} of %{total}",
            answered: survey_answered_count(@state),
            total: survey_path_length(@state)
          )}
        </span>
      </div>

      <.question
        question={@state.current}
        mode={:play}
        answers={@state.answers}
        event="survey_answer"
      />

      <div class="mt-5 flex flex-wrap items-center gap-2">
        <.button
          :if={@state.survey.settings.allow_back && @state.history != []}
          variant="ghost"
          size="sm"
          phx-click="survey_back"
          phx-value-block_id={@block.id}
          id={"survey-back-#{@block.id}"}
        >
          {gettext("Back")}
        </.button>
        <.button
          variant="primary"
          size="sm"
          phx-click="survey_next"
          phx-value-block_id={@block.id}
          id={"survey-next-#{@block.id}"}
        >
          {gettext("Next")}
        </.button>
        <button
          :if={!@state.current.required}
          type="button"
          phx-click="survey_skip"
          phx-value-block_id={@block.id}
          id={"survey-skip-#{@block.id}"}
          class="btn btn-ghost btn-sm text-base-content/50"
        >
          {gettext("Skip this one")}
        </button>
      </div>
    </.survey_shell>
    """
  end

  attr :block, :map, required: true
  attr :state, :map, default: nil
  attr :completed?, :boolean, default: false

  defp survey_notice(assigns) do
    ~H"""
    <.survey_shell title={gettext("Survey unavailable")}>
      <p class="text-sm text-base-content/60">
        {gettext("This survey could not be loaded. Please let your instructor know.")}
      </p>
    </.survey_shell>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp survey_shell(assigns) do
    ~H"""
    <section class="rounded-xl border border-base-300 bg-base-100 p-6 sm:p-8">
      <header class="mb-5 flex items-center gap-3">
        <.icon name="hero-clipboard-document-list" class="size-5 shrink-0 text-primary" />
        <h2 class="font-display font-bold">{@title}</h2>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  # Answers given on this path, counted per question rather than per stored
  # row so a matrix counts once however many rows it has.
  defp survey_answered_count(state) do
    state.answers
    |> Map.keys()
    |> Enum.map(fn {question_id, _row} -> question_id end)
    |> Enum.uniq()
    |> length()
  end

  defp survey_path_length(state) do
    max(length(Surveys.visible_questions(state.flow, state.answers)), 1)
  end

  # -- survey helpers -------------------------------------------------------

  @doc false
  defp fetch_survey(socket, block_id) do
    case Map.get(socket.assigns.survey_state || %{}, block_id) do
      %{status: :open} = state -> {:ok, state}
      _ -> :error
    end
  end

  # A question posts its own id, not the block's - the shared renderer is also
  # used by the builder's preview, which has no block. There are at most a
  # handful of survey blocks on a page, so finding the owner is a scan.
  @doc false
  defp find_survey(socket, question_id) do
    Enum.find_value(socket.assigns.survey_state || %{}, :error, fn {block_id, state} ->
      with %{status: :open, flow: flow} <- state,
           %{} <- Flow.question(flow, question_id) do
        {:ok, block_id, state}
      else
        _ -> nil
      end
    end)
  end

  @doc false
  defp survey_question(state, question_id) do
    case Flow.question(state.flow, question_id) do
      nil -> :error
      question -> {:ok, question}
    end
  end

  @doc false
  defp ensure_response(%{response: %{}} = state, _socket), do: {:ok, state}

  defp ensure_response(state, socket) do
    context = %{
      course_id: socket.assigns.course.id,
      block_id: survey_block_id(socket, state)
    }

    case Surveys.get_or_start_response(state.survey, socket.assigns.current_user, context) do
      {:ok, response} ->
        {:ok, %{state | response: response, answers: Surveys.answers_map(response.id)}}

      {:already_completed, response} ->
        {:ok, %{state | response: response, status: :completed}}

      {:error, _reason} ->
        :error
    end
  end

  defp survey_block_id(socket, state) do
    Enum.find_value(socket.assigns.survey_state || %{}, fn {block_id, candidate} ->
      if candidate[:survey] && candidate.survey.id == state.survey.id, do: block_id
    end)
  end

  # Takes a state whose response already exists: both callers go through
  # `ensure_response/2` first, and advancing without one would mean losing the
  # resume point silently.
  @doc false
  defp advance_survey(socket, block_id, %{response: %{}} = state) do
    case Surveys.next_question(state.flow, state.current, state.answers) do
      :end ->
        {:noreply,
         put_survey_state(socket, block_id, %{state | current: nil, history: state.history})}

      {:question, next} ->
        Surveys.advance_response(state.response, next.id)

        {:noreply,
         put_survey_state(socket, block_id, %{
           state
           | current: next,
             history: [state.current.id | state.history]
         })}
    end
  end

  @doc false
  defp put_survey_state(socket, block_id, state) do
    assign(socket, :survey_state, Map.put(socket.assigns.survey_state, block_id, state))
  end

  @doc false
  defp survey_rank_order(state, question) do
    case Map.get(state.answers, {question.id, ""}) do
      %{value_choice_ids: ids} when is_list(ids) and ids != [] ->
        ids

      _ ->
        question.config |> Map.get("items") |> List.wrap() |> Enum.map(& &1["id"])
    end
  end

  # Marks the block complete and runs the ordinary unlock path, but only if it
  # is not already complete - submitting a survey twice must not re-broadcast
  # progress or re-award anything downstream.
  @doc false
  defp complete_survey_gate(socket, block_id) do
    if block_id in socket.assigns.completed_ids do
      socket
    else
      unlock_next_content(socket, block_id)
    end
  end

  # Computed once per section and kept in assigns: the authoritative
  # engagement filter consults it on every batch, which arrives several times
  # a minute, and it must not become a query.
  @doc false
  defp survey_block_ids(blocks) do
    blocks
    |> Enum.filter(&(&1.type == :survey))
    |> MapSet.new(& &1.id)
  end

  @doc false
  defp load_survey_state(blocks, user) do
    blocks
    |> Enum.filter(&(&1.type == :survey))
    |> Map.new(fn block -> {block.id, build_survey_state(block, user)} end)
  end

  @doc false
  defp build_survey_state(block, user) do
    case Surveys.get_survey(block.content["survey_id"]) do
      nil ->
        %{status: :missing}

      survey ->
        flow = Surveys.load_flow(survey)
        response = Surveys.get_response(survey.id, user.id)

        %{
          survey: survey,
          flow: flow,
          question_count: length(flow.questions),
          response: response,
          answers: response_answers(response),
          current: resume_point(flow, response),
          history: [],
          status: survey_status(survey, response)
        }
    end
  end

  defp response_answers(nil), do: %{}
  defp response_answers(response), do: Surveys.answers_map(response.id)

  # Resuming lands on the question the student left off at. The path they took
  # to get there is not stored, only where they are, so "Back" is unavailable
  # until they move forward again - the alternative would be guessing at a
  # path that branching makes unguessable.
  defp resume_point(flow, nil), do: Surveys.first_question(flow)

  defp resume_point(flow, response) do
    Flow.question(flow, response.current_question_id) ||
      Surveys.first_question(flow)
  end

  defp survey_status(_survey, %{status: :completed}), do: :completed
  defp survey_status(%{status: :published}, _response), do: :open
  defp survey_status(%{status: :closed}, _response), do: :closed
  defp survey_status(_survey, _response), do: :unavailable

  # The section's blocks the user may see, in order. The section is passed
  # to the policy so `:inherit` blocks don't each load it again.
  @doc false
  defp visible_section_blocks(section, user, overrides, opts) do
    opts = Keyword.put(opts, :sections, %{section.id => section})

    section.id
    |> Content.list_blocks_by_section(:all)
    |> Enum.filter(&Content.can_view?(user, &1, overrides, opts))
    |> Enum.sort_by(& &1.order)
  end

  # A `/go/blocks/:id` permalink lands here as `?block=` - reuses the same
  # `scroll_to_block` event/listener the Builder's own deep-linking already
  # relies on (see `maybe_push_scroll/3` there). Safe to call unconditionally
  # (not gated on `connected?`): `push_event` before the socket connects is
  # a documented no-op, and `mount/3` runs again once it does. If the block
  # is gated behind an earlier, still-incomplete block in this same section
  # (not yet in `@visible_blocks`), the listener itself already no-ops on a
  # missing DOM target - no special-casing needed here.
  defp maybe_push_scroll_to_block(socket, nil), do: socket

  defp maybe_push_scroll_to_block(socket, block_id),
    do: push_event(socket, "scroll_to_block", %{id: block_id})

  @doc false
  defp load_pending_file_urls(blocks, drafts) do
    drafts
    |> Enum.filter(fn {block_id, _content} ->
      block = Enum.find(blocks, &(&1.id == block_id))
      block && block.type == :file_assignment
    end)
    |> Enum.map(fn {block_id, content} ->
      {block_id, content["file_urls"] || []}
    end)
    |> Map.new()
  end

  @doc false
  defp subscribe_to_block_topics(blocks, user_id, team_id) do
    # Every block, not just :code - a grade can land on any of them (a
    # teacher grading a quiz_exam/ticket_exam/file_assignment from the
    # grading screen) while the student still has this section open, and
    # `handle_info({:submission_updated, ...})` below already handles any
    # block type generically.
    for block <- blocks do
      Phoenix.PubSub.subscribe(Athena.PubSub, "submission:#{user_id}:#{block.id}")
    end

    if team_id do
      for block <- blocks do
        Learning.subscribe_to_draft_updates(team_id, block.id)
      end
    end
  end

  # Reads through `Athena.Learning.LeaderboardCache`, so every player open
  # on the same competition shares one computation of the board.
  @doc false
  defp load_leaderboard(%{type: :competition} = course),
    do: Learning.get_team_leaderboard(course.id)

  defp load_leaderboard(_course), do: []

  @doc false
  defp load_drafts(user_id, block_ids, team_id),
    do: Learning.get_drafts(user_id, block_ids, team_id)

  @doc false
  defp refresh_exam_holders(socket) do
    assign(
      socket,
      :exam_holders,
      load_exam_holders(
        socket.assigns.blocks,
        socket.assigns.submissions,
        socket.assigns.current_user.id,
        socket.assigns.team_id
      )
    )
  end

  # Which exam blocks a *teammate* is currently sitting, by display name.
  # A competition team shares one attempt, so the rest of the team get a
  # locked card naming the holder instead of a button that would hand them
  # a paper of their own.
  #
  # Derived entirely from submissions already in memory, and short-circuits
  # for everyone outside a team - the individual path costs no extra query
  # and sees an empty map, so nothing about it renders differently.
  @doc false
  defp load_exam_holders(_blocks, _submissions, _user_id, nil), do: %{}

  defp load_exam_holders(blocks, submissions, user_id, _team_id) do
    now = DateTime.utc_now()

    blocks
    |> Enum.filter(&(&1.type in [:quiz_exam, :ticket_exam]))
    |> Enum.flat_map(&held_by_teammate(&1, submissions, user_id, now))
    |> name_exam_holders()
  end

  defp held_by_teammate(block, submissions, user_id, now) do
    submission = Map.get(submissions, block.id)

    if taken_by_teammate?(submission, user_id, now),
      do: [{block.id, submission.account_id}],
      else: []
  end

  # Unfinished, someone else's, and their claim on it has not gone stale.
  defp taken_by_teammate?(%{status: status, account_id: holder} = submission, user_id, now)
       when status in [:pending, :draft, :processing],
       do: holder != user_id and Learning.exam_lock_held?(submission, now)

  defp taken_by_teammate?(_submission, _user_id, _now), do: false

  defp name_exam_holders([]), do: %{}

  defp name_exam_holders(held) do
    accounts =
      held
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Identity.get_accounts_map()

    Map.new(held, fn {block_id, holder_id} -> {block_id, holder_name(accounts, holder_id)} end)
  end

  defp holder_name(accounts, holder_id) do
    case Map.fetch(accounts, holder_id) do
      {:ok, account} -> Identity.display_name(account)
      :error -> gettext("A teammate")
    end
  end

  @doc """
  Handles progression gates. When a student completes a mandatory block,
  this records the progress and dynamically unlocks the rest of the content.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("complete_gate", %{"block-id" => block_id}, socket) do
    user = socket.assigns.current_user
    team_id = socket.assigns.team_id

    {:ok, _} = Learning.mark_completed(user.id, block_id, team_id)

    new_completed_ids = [block_id | socket.assigns.completed_ids]
    linear_lessons = socket.assigns.linear_lessons

    opts = [
      ignore_schedule?: !!socket.assigns[:test_run],
      ignore_visibility?: !!socket.assigns[:test_run]
    ]

    accessible_ids =
      Learning.accessible_section_ids(
        user,
        socket.assigns.course.id,
        linear_lessons,
        socket.assigns.overrides,
        team_id,
        opts
      )

    current_index = Enum.find_index(linear_lessons, fn s -> s.id == socket.assigns.section.id end)
    next_section = Enum.at(linear_lessons, current_index + 1)
    next_accessible? = next_section != nil and next_section.id in accessible_ids

    {:noreply,
     socket
     |> assign(:completed_ids, new_completed_ids)
     |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
     |> assign(:visible_blocks, calc_visible_blocks(socket.assigns.blocks, new_completed_ids))}
  end

  def handle_event("open_course_map", _, socket),
    do: {:noreply, assign(socket, course_map_open: true)}

  def handle_event("close_course_map", _, socket),
    do: {:noreply, assign(socket, course_map_open: false)}

  def handle_event("open_leaderboard", _, socket),
    do: {:noreply, assign(socket, leaderboard_open: true)}

  def handle_event("close_leaderboard", _, socket),
    do: {:noreply, assign(socket, leaderboard_open: false)}

  @impl true
  def handle_event("start_exam", %{"block_id" => block_id}, socket) do
    case Enum.find(socket.assigns.blocks, &(&1.id == block_id)) do
      %{type: type} = block when type in [:quiz_exam, :ticket_exam] ->
        start_exam_for_block(socket, block)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("continue_exam", %{"block_id" => block_id}, socket) do
    # The button is not rendered while a teammate holds the attempt, but a
    # crafted event must not reach the exam LiveView just to be bounced.
    if Map.has_key?(socket.assigns.exam_holders || %{}, block_id) do
      {:noreply, socket}
    else
      block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))
      enter_exam(socket, block_id, block && block.type)
    end
  end

  @impl true
  def handle_event("submit_quiz", %{"block_id" => block_id} = params, socket) do
    case Enum.find(socket.assigns.blocks, &(&1.id == block_id)) do
      nil ->
        {:noreply, socket}

      block ->
        handle_quiz_submission(socket, block, params["answer"])
    end
  end

  @impl true
  def handle_event(
        "request_media_upload",
        %{"block_id" => block_id, "media_type" => "file_assignment"},
        socket
      ) do
    with %{} = block <- Enum.find(socket.assigns.blocks, &(&1.id == block_id)),
         true <- block.type == :file_assignment do
      max_files = block.content["max_files"] || 1
      current_count = length(Map.get(socket.assigns.pending_file_urls, block_id, []))

      {:noreply,
       socket
       |> assign(:show_media_modal, true)
       |> assign(:active_upload_block_id, block_id)
       |> assign(:upload_type, "file_assignment")
       |> assign(:max_files_for_upload, max_files)
       |> assign(:current_file_count_for_upload, current_count)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Invalid block for file upload"))}
    end
  end

  def handle_event(
        "request_media_upload",
        %{"block_id" => block_id, "media_type" => type},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:show_media_modal, true)
     |> assign(:active_upload_block_id, block_id)
     |> assign(:upload_type, type)
     |> assign(:max_files_for_upload, 1)
     |> assign(:current_file_count_for_upload, 0)}
  end

  def handle_event("media_upload_clipboard_request", params, socket) do
    %{"file_name" => file_name, "temp_id" => temp_id} = params

    bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena"
    course_id = socket.assigns.course.id
    unique_id = Ecto.UUID.generate()
    clean_name = file_name |> String.replace(~r/[^a-zA-Z0-9_\-\.]/, "_")
    key = "courses/#{course_id}/#{unique_id}-#{clean_name}"

    case Athena.Media.generate_upload_url(bucket, key) do
      {:ok, upload_url} ->
        path_segments = String.split(key, "/")
        final_url = ~p"/media/#{path_segments}"

        {:noreply,
         push_event(socket, "media_upload_presigned", %{
           temp_id: temp_id,
           upload_url: upload_url,
           final_url: final_url
         })}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not generate upload URL"))}
    end
  end

  def handle_event(
        "media_upload_clipboard_success",
        %{"block_id" => block_id, "final_url" => url},
        socket
      ) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block && to_string(block.type) == "file_assignment" do
      pending = socket.assigns[:pending_file_urls] || %{}
      current_urls = Map.get(pending, block_id, [])
      max_files = block.content["max_files"] || 1

      if length(current_urls) < max_files do
        updated_pending = Map.put(pending, block_id, current_urls ++ [url])
        save_file_assignment_draft(socket, block_id, updated_pending[block_id])
        {:noreply, assign(socket, :pending_file_urls, updated_pending)}
      else
        {:noreply, put_flash(socket, :error, gettext("Maximum number of files reached."))}
      end
    else
      {:noreply,
       push_event(socket, "insert_media", %{
         block_id: block_id,
         url: url,
         type: "tiptap_image"
       })}
    end
  end

  def handle_event("cancel_media_upload", _, socket) do
    {:noreply,
     socket
     |> assign(:show_media_modal, false)
     |> assign(:active_upload_block_id, nil)
     |> assign(:upload_type, nil)}
  end

  def handle_event("submit_file_assignment", %{"block_id" => block_id}, socket) do
    file_urls =
      socket.assigns.pending_file_urls
      |> Map.get(block_id, [])
      |> Enum.reject(&(&1 == ""))

    with {:files?, true} <- {:files?, file_urls != []},
         sub_attrs <- build_file_submission_attrs(block_id, socket.assigns, file_urls),
         {:ok, submission} <-
           Athena.Learning.create_submission(socket.assigns.current_user, sub_attrs) do
      {:noreply, handle_successful_file_submission(socket, block_id, submission)}
    else
      {:files?, false} ->
        {:noreply, put_flash(socket, :error, gettext("Please upload at least one file"))}

      {:error, changeset} ->
        {:noreply, handle_failed_file_submission(socket, changeset)}
    end
  end

  def handle_event("submit_code", params, socket) do
    block_id = params["block_id"]
    code = get_in(params, ["answer", "code"]) || ""

    with block when not is_nil(block) <- Enum.find(socket.assigns.blocks, &(&1.id == block_id)),
         true <- Execution.runner_available?(block.content["language"]) do
      process_code_submission(socket, block, code)
    else
      nil ->
        {:noreply, socket}

      false ->
        {:noreply, put_flash(socket, :error, gettext("Runner node is not connected!"))}
    end
  end

  @impl true
  def handle_event("run_code", %{"block_id" => block_id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))
    draft = Map.get(socket.assigns.drafts || %{}, block_id)
    submission = Map.get(socket.assigns.submissions || %{}, block_id)

    socket = EngagementSignals.emit_code_run_attempt(socket, block_id)

    do_run_code(socket, block, draft, submission)
  end

  def handle_event(
        "remove_pending_file",
        %{"block_id" => block_id, "url" => url},
        socket
      ) do
    pending = Map.get(socket.assigns, :pending_file_urls, %{})
    current = Map.get(pending, block_id, [])
    updated = List.delete(current, url)
    updated_pending = Map.put(pending, block_id, updated)

    save_file_assignment_draft(socket, block_id, updated)

    {:noreply, assign(socket, :pending_file_urls, updated_pending)}
  end

  def handle_event("save_draft", %{"block_id" => block_id} = params, socket) do
    user = socket.assigns.current_user
    team_id = socket.assigns.team_id
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))
    existing_draft = Map.get(socket.assigns.drafts || %{}, block_id) || %{}

    content = build_draft_content(block, params, existing_draft)

    case Learning.save_draft(user, block_id, content, team_id) do
      {:ok, _submission} ->
        new_drafts = Map.put(socket.assigns.drafts || %{}, block_id, content)

        socket =
          socket
          |> assign(:drafts, new_drafts)
          |> EngagementSignals.record_quiz_interaction(block)

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_event("update_content", %{"id" => block_id, "content" => content}, socket) do
    params = %{"block_id" => block_id, "answer" => content}
    handle_event("save_draft", params, socket)
  end

  # -- surveys --------------------------------------------------------------
  #
  # A survey block behaves like any other block: it renders in place and the
  # player never navigates away from the lesson for it, unlike `:quiz_exam`
  # and `:ticket_exam`, which take over the screen.
  #
  # The response row is created lazily, on the first answer or the first step
  # forward, rather than when the page loads. Opening a lesson is not
  # answering a survey, and auto-creating a row for everyone who scrolled past
  # would fill the results with empty responses and make the completion funnel
  # meaningless.

  def handle_event("survey_answer", %{"question_id" => question_id} = params, socket) do
    with {:ok, block_id, state} <- find_survey(socket, question_id),
         {:ok, question} <- survey_question(state, question_id),
         {:ok, state} <- ensure_response(state, socket) do
      value = Surveys.cast_answer_params(question.type, params)

      case Surveys.save_answer(state.response, question, value) do
        {:ok, answer} ->
          answers = Map.put(state.answers, {question.id, answer.row_key}, answer)
          {:noreply, put_survey_state(socket, block_id, %{state | answers: answers})}

        {:error, _changeset} ->
          # A malformed value is dropped rather than stored as nothing: a
          # blank is a different finding from a bad entry, and the student
          # still sees what they typed.
          {:noreply, put_survey_state(socket, block_id, state)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("survey_skip", %{"block_id" => block_id}, socket) do
    with {:ok, state} <- fetch_survey(socket, block_id),
         %{} = question <- state.current,
         {:ok, state} <- ensure_response(state, socket),
         {:ok, answer} <- Surveys.skip_answer(state.response, question) do
      answers = Map.put(state.answers, {question.id, answer.row_key}, answer)

      advance_survey(socket, block_id, %{state | answers: answers})
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("survey_next", %{"block_id" => block_id}, socket) do
    with {:ok, state} <- fetch_survey(socket, block_id),
         {:ok, state} <- ensure_response(state, socket) do
      advance_survey(socket, block_id, state)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("survey_back", %{"block_id" => block_id}, socket) do
    with {:ok, state} <- fetch_survey(socket, block_id),
         {:question, previous, rest} <- Surveys.previous_question(state.flow, state.history) do
      state = %{state | current: previous, history: rest}

      if state.response, do: Surveys.advance_response(state.response, previous.id)

      {:noreply, put_survey_state(socket, block_id, state)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("survey_submit", %{"block_id" => block_id}, socket) do
    with {:ok, state} <- fetch_survey(socket, block_id),
         {:ok, state} <- ensure_response(state, socket),
         {:ok, response} <- Surveys.complete_response(state.response) do
      socket =
        put_survey_state(socket, block_id, %{
          state
          | response: response,
            status: :completed,
            current: nil
        })

      # The gate is the ordinary one, so `completion_rule: :submit` on a survey
      # block behaves exactly as it does on any other block and the rest of
      # the player needs no special case.
      {:noreply, complete_survey_gate(socket, block_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Ranking is the one question type that is not a form: SortableJS reports a
  # move and the resulting order is computed from what is on screen. The
  # dataset arrives camelCased.
  def handle_event(
        "survey_rank",
        %{"questionId" => question_id, "id" => item_id, "new_index" => new_index},
        socket
      ) do
    with {:ok, block_id, state} <- find_survey(socket, question_id),
         {:ok, question} <- survey_question(state, question_id),
         {:ok, state} <- ensure_response(state, socket) do
      reordered =
        state
        |> survey_rank_order(question)
        |> List.delete(item_id)
        |> List.insert_at(new_index, item_id)

      case Surveys.save_answer(state.response, question, %{"choice_ids" => reordered}) do
        {:ok, answer} ->
          answers = Map.put(state.answers, {question.id, answer.row_key}, answer)
          {:noreply, put_survey_state(socket, block_id, %{state | answers: answers})}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("engagement_batch", %{"events" => events}, socket) do
    section_id = socket.assigns.section.id

    normalized =
      events
      |> Enum.map(&Engagement.normalize_event(&1, section_id))
      |> Enum.reject(&is_nil/1)
      # Before `record_events/4` *and* before the nudge reduce: a survey
      # collects nothing, and a nudge about one would be telemetry by another
      # name - the student would be told the server is watching how long they
      # spend on a feedback question.
      |> Engagement.reject_survey_events(socket.assigns.survey_block_ids)

    {buffered, socket} = EngagementSignals.take_buffered_events(socket)

    # A builder "test run" plays through as a throwaway ephemeral account
    # (see `Athena.Learning.TestRuns`) that `TestRuns.cleanup/1` never
    # scrubs from `engagement_events` - so instructors previewing a course
    # must never write real telemetry rows in the first place.
    unless socket.assigns.test_run do
      Engagement.record_events(
        socket.assigns.current_user.id,
        socket.assigns.cohort_id,
        socket.assigns.engagement_session_id,
        normalized ++ buffered
      )
    end

    socket = Enum.reduce(normalized, socket, &maybe_nudge/2)

    {:noreply, socket}
  end

  def handle_event("save_draft", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "reorder_matching_answer",
        %{"blockId" => block_id, "old_index" => old_index, "new_index" => new_index},
        socket
      ) do
    move_matching_answer_to_index(socket, block_id, old_index, new_index)
  end

  def handle_event(
        "move_matching_answer_up",
        %{"block_id" => block_id, "id" => pair_id},
        socket
      ) do
    shift_matching_answer(socket, block_id, pair_id, -1)
  end

  def handle_event(
        "move_matching_answer_down",
        %{"block_id" => block_id, "id" => pair_id},
        socket
      ) do
    shift_matching_answer(socket, block_id, pair_id, 1)
  end

  # Tracks this student's own pending viewport_enter timestamps (a simple
  # per-session map - not to be confused with `Athena.Engagement.BlockStats`,
  # which pairs enter/exit across the whole cohort for the aggregate
  # distribution), plus per-block scroll depth and video forward-skip
  # accumulators. Each raw event type below feeds exactly one independent
  # nudge reason - `nudged_block_ids` is keyed by `{block_id, reason}` so
  # different reasons on the same block don't block each other, but the same
  # reason never repeats within one session.
  @doc false
  defp maybe_nudge(%{event_type: :viewport_enter} = event, socket) do
    pending = Map.put(socket.assigns.engagement_pending_enters, event.block_id, event.occurred_at)
    assign(socket, :engagement_pending_enters, pending)
  end

  defp maybe_nudge(%{event_type: :viewport_exit} = event, socket) do
    {entered_at, pending} = Map.pop(socket.assigns.engagement_pending_enters, event.block_id)

    {max_scroll_percent, scroll_progress} =
      Map.pop(socket.assigns.engagement_scroll_progress, event.block_id, 0)

    socket =
      socket
      |> assign(:engagement_pending_enters, pending)
      |> assign(:engagement_scroll_progress, scroll_progress)

    block = Enum.find(socket.assigns.blocks, &(&1.id == event.block_id))

    shallow_scroll? =
      block != nil and block.type == :text and max_scroll_percent < min_scroll_percent_for_text()

    socket = maybe_trigger(socket, event.block_id, :shallow_scroll, shallow_scroll?)

    cond do
      is_nil(entered_at) ->
        socket

      # A more specific signal already covered this exit (or a past one for
      # this block) - don't also pile on with the generic "too fast" nudge.
      nudged?(socket, event.block_id, :shallow_scroll) ->
        socket

      nudged?(socket, event.block_id, :fast_dwell) ->
        socket

      true ->
        elapsed = DateTime.diff(event.occurred_at, entered_at, :second)
        decide_fast_dwell_nudge(socket, event.block_id, elapsed)
    end
  end

  defp maybe_nudge(%{event_type: :scroll_milestone} = event, socket) do
    percent = event.payload["percent"] || 0

    progress =
      Map.update(
        socket.assigns.engagement_scroll_progress,
        event.block_id,
        percent,
        &max(&1, percent)
      )

    assign(socket, :engagement_scroll_progress, progress)
  end

  defp maybe_nudge(%{event_type: :paste_detected} = event, socket) do
    pasted = event.payload["pasted_chars"] || 0
    total = event.payload["total_chars"] || 0
    heavy_paste? = total > 0 and pasted / total > paste_ratio_nudge_threshold()

    maybe_trigger(socket, event.block_id, :heavy_paste, heavy_paste?)
  end

  defp maybe_nudge(%{event_type: :video_seek} = event, socket) do
    from_sec = event.payload["from_sec"] || 0
    to_sec = event.payload["to_sec"] || 0
    forward_delta = max(to_sec - from_sec, 0)

    skip =
      Map.update(
        socket.assigns.engagement_video_forward_skip,
        event.block_id,
        forward_delta,
        &(&1 + forward_delta)
      )

    assign(socket, :engagement_video_forward_skip, skip)
  end

  defp maybe_nudge(%{event_type: :video_ended} = event, socket) do
    {skipped_seconds, skip_map} =
      Map.pop(socket.assigns.engagement_video_forward_skip, event.block_id, 0)

    socket = assign(socket, :engagement_video_forward_skip, skip_map)

    duration = event.payload["duration"]

    video_skipped? =
      is_number(duration) and duration > 0 and
        skipped_seconds / duration > video_skip_ratio_threshold()

    maybe_trigger(socket, event.block_id, :video_skipped, video_skipped?)
  end

  defp maybe_nudge(_event, socket), do: socket

  @doc false
  defp decide_fast_dwell_nudge(socket, block_id, elapsed_seconds) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      resolved_rule = Policy.resolve_engagement_rule(block, socket.assigns.section)

      case Engagement.evaluate_nudge(
             socket.assigns.cohort_id,
             block_id,
             resolved_rule,
             elapsed_seconds,
             socket.assigns.nudges_enabled
           ) do
        :nudge -> nudge_student(socket, block_id, :fast_dwell)
        :ok -> socket
      end
    else
      socket
    end
  end

  # Shared entry point for the three threshold-based reasons (shallow scroll,
  # heavy paste, skipped video) - unlike `:fast_dwell`, these don't need
  # `Athena.Engagement.evaluate_nudge/5`'s cohort-percentile comparison
  # (scroll depth and paste ratio are far less content-dependent than "how
  # long should this take", so one global threshold is enough), but they
  # still have to respect the same on/off switches.
  @doc false
  defp maybe_trigger(socket, _block_id, _reason, false), do: socket

  defp maybe_trigger(socket, block_id, reason, true) do
    if nudged?(socket, block_id, reason) do
      socket
    else
      with block when not is_nil(block) <- Enum.find(socket.assigns.blocks, &(&1.id == block_id)),
           resolved_rule <- Policy.resolve_engagement_rule(block, socket.assigns.section),
           true <- socket.assigns.nudges_enabled and resolved_rule.nudge_enabled do
        nudge_student(socket, block_id, reason)
      else
        _ -> socket
      end
    end
  end

  @doc false
  defp nudged?(socket, block_id, reason),
    do: MapSet.member?(socket.assigns.nudged_block_ids, {block_id, reason})

  @doc false
  defp nudge_student(socket, block_id, reason) do
    EngagementSignals.emit_engagement_event(socket, block_id, :nudge_shown, %{
      "reason" => to_string(reason)
    })

    socket
    |> assign(:nudged_block_ids, MapSet.put(socket.assigns.nudged_block_ids, {block_id, reason}))
    |> put_flash(:info, nudge_message(reason))
  end

  @doc false
  defp nudge_message(:shallow_scroll),
    do: gettext("Looks like you scrolled past without reading much - want to go back?")

  defp nudge_message(:heavy_paste),
    do: gettext("Looks like you pasted a ready-made answer - are you sure you understand it?")

  defp nudge_message(:video_skipped),
    do: gettext("You skipped through most of that video - sure you got it all?")

  defp nudge_message(_fast_dwell),
    do: gettext("You went through that pretty fast - want to go back and double-check?")

  defp engagement_config, do: Application.get_env(:athena, Athena.Engagement, [])

  defp min_scroll_percent_for_text,
    do: Keyword.get(engagement_config(), :min_scroll_percent_for_text, 70)

  defp paste_ratio_nudge_threshold,
    do: Keyword.get(engagement_config(), :paste_ratio_nudge_threshold, 0.8)

  defp video_skip_ratio_threshold,
    do: Keyword.get(engagement_config(), :video_skip_ratio_threshold, 0.3)

  defp do_run_code(socket, nil, _draft, _submission), do: {:noreply, socket}

  defp do_run_code(socket, %{type: :code} = block, draft, submission) do
    # Same fallback chain the editor is actually rendered with
    # (`compute_code_for_mode/5`, mode `:play`): draft, then last submission,
    # then the block's initial/template code. Reading only `draft` here used
    # to mean "Run" silently no-op'd (or flashed on a nested test-run player
    # with no visible flash outlet) whenever the student hadn't yet *edited*
    # a block that already had a submission or template code showing.
    code = compute_code_for_mode(:play, block, draft, %{}, submission)

    cond do
      String.trim(code) == "" ->
        {:noreply, put_flash(socket, :error, gettext("Please write some code first!"))}

      not Execution.runner_available?(block.content["language"]) ->
        {:noreply, put_flash(socket, :error, gettext("Runner node is not connected!"))}

      true ->
        case Learning.test_code(socket.assigns.current_user, block, code) do
          {:ok, _draft} ->
            new_drafts = Map.put(socket.assigns.drafts || %{}, block.id, %{"code" => code})
            {:noreply, assign(socket, :drafts, new_drafts)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to enqueue code execution."))}
        end
    end
  end

  defp do_run_code(socket, _block, _draft, _submission), do: {:noreply, socket}

  @doc false
  defp build_file_submission_attrs(block_id, assigns, file_urls) do
    %{
      "block_id" => block_id,
      "account_id" => assigns.current_user.id,
      "cohort_id" => assigns.team_id,
      "status" => :pending,
      "content" => %{
        type: :file_assignment,
        file_urls: file_urls
      }
    }
  end

  @doc false
  defp handle_successful_file_submission(socket, block_id, submission) do
    new_submissions = Map.put(socket.assigns.submissions || %{}, block_id, submission)
    new_pending = Map.update!(socket.assigns.pending_file_urls, block_id, fn _ -> [] end)

    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    socket
    |> assign(:submissions, new_submissions)
    |> assign(:pending_file_urls, new_pending)
    |> process_gate_after_submission(block, submission)
    |> put_flash(:info, gettext("Assignment submitted!"))
  end

  @doc false
  defp handle_failed_file_submission(socket, changeset) do
    error_msg =
      changeset.errors
      |> Keyword.values()
      |> Enum.map_join(", ", fn {msg, _} -> msg end)

    put_flash(socket, :error, error_msg)
  end

  @doc false
  defp process_code_submission(socket, block, code) do
    sub_attrs = %{
      "block_id" => block.id,
      "cohort_id" => socket.assigns.team_id,
      "status" => :pending,
      "content" => %{"type" => :code, "code" => code}
    }

    case Learning.create_submission(socket.assigns.current_user, sub_attrs) do
      {:ok, submission} ->
        submissions = Map.put(socket.assigns.submissions, block.id, submission)
        {:noreply, assign(socket, submissions: submissions)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to submit code."))}
    end
  end

  @doc false
  defp start_exam_for_block(socket, block) do
    user = socket.assigns.current_user
    time_limit_sec = get_time_limit_sec(block)

    case Learning.get_or_create_exam_attempt(
           socket.assigns.course.id,
           user.id,
           block.id,
           block.type,
           socket.assigns.team_id,
           time_limit_sec,
           block.content
         ) do
      {:ok, _submission} ->
        enter_exam(socket, block.id, block.type)

      # Stale client state (e.g. a second tab) clicking "Start" on an attempt
      # that already finished elsewhere - refresh instead of a fresh attempt.
      {:already_completed, updated_sub} ->
        {:noreply,
         assign(
           socket,
           :submissions,
           Map.put(socket.assigns.submissions, block.id, updated_sub)
         )}

      # A teammate got there first and this page had not heard yet. Show
      # the locked card straight away rather than leaving a button that
      # keeps failing.
      {:taken_by_teammate, held_sub} ->
        {:noreply,
         socket
         |> assign(:submissions, Map.put(socket.assigns.submissions, block.id, held_sub))
         |> refresh_exam_holders()
         |> put_flash(:info, gettext("A teammate is already taking this for your team."))}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to start the assessment session.")
         )}
    end
  end

  # Enters the exam/ticket LiveView for `block_id`: a real page navigation
  # normally, but nested inside the builder's "test run" modal, navigating
  # the real browser away would exit the sandbox entirely (and land on the
  # instructor's own real account, not the test-run one) - so instead this
  # tells the parent (the builder) to swap its live_render from this module
  # to `AthenaWeb.LearnLive.Exam`/`TicketExam` for the same block, which
  # then mounts nested exactly like this LiveView already does (see its own
  # `mount(:not_mounted_at_router, ...)` clause).
  @doc false
  defp enter_exam(socket, block_id, block_type) do
    if socket.assigns[:test_run] do
      send(socket.parent_pid, {:test_run_enter_exam, block_id, block_type})
      {:noreply, socket}
    else
      course_id = socket.assigns.course.id
      return_to = ~p"/learn/courses/#{course_id}/play/#{socket.assigns.section.id}"

      route =
        if block_type == :ticket_exam do
          ~p"/learn/courses/#{course_id}/ticket/#{block_id}?return_to=#{return_to}"
        else
          ~p"/learn/courses/#{course_id}/exam/#{block_id}?return_to=#{return_to}"
        end

      {:noreply, push_navigate(socket, to: route)}
    end
  end

  @doc false
  defp get_time_limit_sec(block) do
    content = block.content || %{}

    case Map.get(content, "time_limit") do
      nil ->
        3600

      minutes when is_integer(minutes) ->
        minutes * 60

      minutes when is_binary(minutes) ->
        case Integer.parse(minutes) do
          {mins, _} -> mins * 60
          :error -> 3600
        end
    end
  end

  @doc false
  defp handle_quiz_submission(socket, block, answer) do
    answer = resolve_quiz_answer(socket, block, answer)

    sub_attrs = %{
      "account_id" => socket.assigns.current_user.id,
      "block_id" => block.id,
      "cohort_id" => socket.assigns.team_id,
      "status" => :pending,
      "content" => build_submission_content(block, answer)
    }

    case Learning.create_submission(socket.assigns.current_user, sub_attrs) do
      {:ok, submission} ->
        eval_result = Learning.evaluate_sync(submission)
        {:ok, final_sub} = Learning.system_update_submission(submission, eval_result)

        submissions = Map.put(socket.assigns.submissions || %{}, block.id, final_sub)
        new_drafts = Map.delete(socket.assigns.drafts || %{}, block.id)

        socket = assign(socket, submissions: submissions, drafts: new_drafts)
        socket = process_gate_after_submission(socket, block, final_sub)

        {flash_type, flash_msg} = build_quiz_flash(final_sub)

        {:noreply, put_flash(socket, flash_type, flash_msg)}

      {:error, changeset} ->
        error_msg =
          changeset.errors
          |> Keyword.values()
          |> Enum.map_join(", ", fn {msg, _} -> msg end)

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @doc false
  defp resolve_quiz_answer(socket, %{content: %{"question_type" => "matching"}} = block, _answer) do
    current_matching_order(socket, block)
  end

  defp resolve_quiz_answer(_socket, _block, answer), do: answer

  @doc false
  defp current_matching_order(socket, block) do
    pairs = block.content["pairs"] || []
    draft = Map.get(socket.assigns.drafts || %{}, block.id) || %{}

    case draft["matches"] do
      list when is_list(list) and list != [] ->
        list

      _ ->
        initial_matching_order(pairs, block.id, socket.assigns.current_user.id)
    end
  end

  @doc false
  defp move_item(list, old_index, new_index) do
    {item, rest} = List.pop_at(list, old_index)
    List.insert_at(rest, new_index, item)
  end

  @doc false
  defp move_matching_answer_to_index(socket, block_id, old_index, new_index) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      current_order = current_matching_order(socket, block)
      new_order = move_item(current_order, old_index, new_index)
      persist_matching_draft(socket, block_id, new_order)
    else
      {:noreply, socket}
    end
  end

  @doc false
  defp shift_matching_answer(socket, block_id, pair_id, delta) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      current_order = current_matching_order(socket, block)
      old_index = Enum.find_index(current_order, &(&1 == pair_id))
      apply_matching_shift(socket, block_id, current_order, old_index, delta)
    else
      {:noreply, socket}
    end
  end

  @doc false
  defp apply_matching_shift(socket, _block_id, _current_order, nil, _delta),
    do: {:noreply, socket}

  defp apply_matching_shift(socket, block_id, current_order, old_index, delta) do
    new_index = (old_index + delta) |> max(0) |> min(length(current_order) - 1)

    if new_index == old_index do
      {:noreply, socket}
    else
      new_order = move_item(current_order, old_index, new_index)
      persist_matching_draft(socket, block_id, new_order)
    end
  end

  @doc false
  defp persist_matching_draft(socket, block_id, new_order) do
    user = socket.assigns.current_user
    team_id = socket.assigns.team_id
    content = %{"type" => :quiz_question, "matches" => new_order}

    case Learning.save_draft(user, block_id, content, team_id) do
      {:ok, _submission} ->
        new_drafts = Map.put(socket.assigns.drafts || %{}, block_id, content)
        {:noreply, assign(socket, :drafts, new_drafts)}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  @doc false
  defp build_quiz_flash(final_sub) do
    cond do
      final_sub.status == :needs_review ->
        {:info, gettext("Answer submitted. Waiting for instructor review.")}

      final_sub.score == 100 ->
        {:info, gettext("Correct!")}

      true ->
        {:error, gettext("Incorrect. Please try again.")}
    end
  end

  @doc false
  defp calc_visible_blocks(blocks, completed_ids) do
    {visible, _blocked?} =
      Enum.reduce(blocks, {[], false}, fn block, {acc, blocked?} ->
        reset? = block.access_rules && block.access_rules.reset_waterline
        current_blocked? = if reset?, do: false, else: blocked?

        is_completed = block.id in completed_ids

        if current_blocked? do
          {acc, true}
        else
          new_acc = acc ++ [block]
          next_blocked? = gate?(block) and not is_completed

          {new_acc, next_blocked?}
        end
      end)

    visible
  end

  @doc false
  defp build_submission_content(block, answer) do
    q_type = block.content["question_type"]
    answer_type = block.content["answer_type"] || "plain_text"
    build_submission_for_type(q_type, answer_type, answer)
  end

  @doc false
  defp build_submission_for_type("exact_match", _answer_type, answer),
    do: %{"type" => "quiz_question", "text_answer" => answer || ""}

  defp build_submission_for_type("open", "rich_text", answer),
    do: %{"type" => "quiz_question", "rich_answer" => parse_rich_answer(answer)}

  defp build_submission_for_type("open", _answer_type, answer),
    do: %{"type" => "quiz_question", "text_answer" => answer || ""}

  defp build_submission_for_type("single", _answer_type, answer),
    do: %{"type" => "quiz_question", "selected_choices" => if(answer, do: [answer], else: [])}

  defp build_submission_for_type("multiple", _answer_type, answer),
    do: %{"type" => "quiz_question", "selected_choices" => List.wrap(answer)}

  defp build_submission_for_type("matching", _answer_type, answer),
    do: %{"type" => "quiz_question", "matches" => answer || []}

  defp build_submission_for_type(_q_type, _answer_type, _answer), do: %{"type" => "quiz_question"}

  @doc false
  defp parse_rich_answer(nil), do: ""
  defp parse_rich_answer(""), do: ""

  defp parse_rich_answer(val) when is_binary(val) do
    if String.starts_with?(val, "{") do
      case Jason.decode(val) do
        {:ok, decoded} -> decoded
        _ -> val
      end
    else
      val
    end
  end

  defp parse_rich_answer(val), do: val

  @doc false
  defp handle_block_submission_update(socket, block, submission) do
    submissions = Map.put(socket.assigns.submissions, submission.block_id, submission)

    socket =
      socket
      |> assign(submissions: submissions)
      |> refresh_block_feedback(submission.block_id)

    # Only a finished, real attempt can complete the block: the same
    # submission is broadcast again on every status change (pending,
    # processing, graded), and a code test run reuses the draft row with
    # `is_test_run` - neither may pass a `:submit` gate.
    socket =
      if finished_attempt?(submission),
        do: process_gate_after_submission(socket, block, submission),
        else: socket

    socket =
      cond do
        submission.status in [:pending, :processing, :draft] ->
          socket

        # `build_code_flash/1` and the "code_run_result" event are specific
        # to the code sandbox's own run/attempt cycle - a manually graded
        # type (quiz_exam, ticket_exam, file_assignment, ...) gets its own,
        # simpler "you were graded" flash below instead.
        block.type == :code ->
          socket = EngagementSignals.emit_code_run_result(socket, block.id, submission.status)

          {flash_type, flash_msg} = build_code_flash(submission)
          put_flash(socket, flash_type, flash_msg)

        submission.status == :rejected ->
          put_flash(socket, :error, gettext("Your submission was rejected by the instructor."))

        submission.status == :needs_review ->
          socket

        true ->
          put_flash(socket, :info, gettext("Your submission was graded."))
      end

    {:noreply, socket}
  end

  defp finished_attempt?(%{status: status} = submission) do
    status not in [:draft, :pending, :processing] and not test_run_content?(submission.content)
  end

  # `content` is a plain map when loaded from the database, but a test may
  # hand over a `SubmissionContent` struct (which has no `is_test_run`).
  defp test_run_content?(%{"is_test_run" => true}), do: true
  defp test_run_content?(_content), do: false

  @doc false
  defp process_gate_after_submission(socket, block, submission) do
    cond do
      block.id in socket.assigns.completed_ids ->
        socket

      Learning.block_solved?(block, submission) ->
        unlock_next_content(socket, block.id)

      true ->
        socket
    end
  end

  @doc false
  defp unlock_next_content(socket, block_id) do
    user = socket.assigns.current_user
    team_id = socket.assigns.team_id

    {:ok, _} = Learning.mark_completed(user.id, block_id, team_id)

    new_completed_ids = [block_id | socket.assigns.completed_ids]
    linear_lessons = socket.assigns.linear_lessons

    opts = [
      ignore_schedule?: !!socket.assigns[:test_run],
      ignore_visibility?: !!socket.assigns[:test_run]
    ]

    accessible_ids =
      Learning.accessible_section_ids(
        user,
        socket.assigns.course.id,
        linear_lessons,
        socket.assigns.overrides,
        team_id,
        opts
      )

    current_index =
      Enum.find_index(linear_lessons, fn s -> s.id == socket.assigns.section.id end)

    next_section = Enum.at(linear_lessons, current_index + 1)
    next_accessible? = next_section != nil and next_section.id in accessible_ids

    socket
    |> assign(:completed_ids, new_completed_ids)
    |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
    |> assign(:visible_blocks, calc_visible_blocks(socket.assigns.blocks, new_completed_ids))
  end

  # Teammates' progress, grading and every builder autosave all broadcast a
  # refresh; bursts of them are folded into one reload per debounce window.
  @default_refresh_debounce_ms 1_500

  @doc """
  The debounce window for live refreshes, in ms (`0` refreshes at once, as
  in tests). Shared with `AthenaWeb.LearnLive.Course`: builder edits
  refresh both the same way. Read at runtime, not compiled in, so the
  value can differ per environment without the compiler treating the
  other branches as dead code.
  """
  @spec refresh_debounce_ms() :: non_neg_integer()
  def refresh_debounce_ms do
    :athena
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:refresh_debounce_ms, @default_refresh_debounce_ms)
  end

  @doc false
  defp request_refresh(socket, kind) do
    case {refresh_debounce_ms(), socket.assigns.refresh_pending} do
      {0, _pending} ->
        refresh(socket, kind)

      {delay, nil} ->
        Process.send_after(self(), :do_refresh, delay)
        assign(socket, :refresh_pending, kind)

      {_delay, pending} ->
        assign(socket, :refresh_pending, merge_refresh_kind(pending, kind))
    end
  end

  defp merge_refresh_kind(:content, _kind), do: :content
  defp merge_refresh_kind(_pending, kind), do: kind

  # Re-evaluates access and progress; if the current section was hidden or
  # locked, sends the student back to the syllabus. `kind`:
  #   * `:progress` - someone's progress or a grade changed: the section's
  #     blocks are unchanged, so they aren't reloaded;
  #   * `:schedule` - an unlock/lock time passed: block visibility may change;
  #   * `:content` - the course itself was edited: also reloads the unlock
  #     schedule.
  @doc false
  defp refresh(socket, kind) do
    user = socket.assigns.current_user
    course_id = socket.assigns.course.id
    cohort_id = socket.assigns.cohort_id
    team_id = socket.assigns.team_id
    current_section_id = socket.assigns.section.id

    opts = [
      ignore_schedule?: !!socket.assigns[:test_run],
      ignore_visibility?: !!socket.assigns[:test_run]
    ]

    overrides = Learning.get_student_overrides(user.id, course_id, cohort_id)
    outline = Content.course_outline(course_id, user, overrides, opts)
    linear_lessons = outline.linear_lessons

    accessible_ids =
      Learning.accessible_section_ids(user, course_id, linear_lessons, overrides, team_id, opts)

    with true <- current_section_id in accessible_ids,
         {:ok, section} <- Content.get_section(current_section_id) do
      blocks =
        if kind == :progress,
          do: socket.assigns.blocks,
          else: visible_section_blocks(section, user, overrides, opts)

      block_ids = Enum.map(blocks, & &1.id)
      completed_ids = Learning.completed_block_ids(user.id, current_section_id, team_id)
      submissions = Learning.get_latest_submissions(user.id, block_ids, team_id)
      feedback_map = Learning.get_feedback_map(user.id, block_ids, team_id)

      current_index = Enum.find_index(linear_lessons, fn s -> s.id == current_section_id end)
      next_section = current_index && Enum.at(linear_lessons, current_index + 1)
      next_accessible? = next_section != nil and next_section.id in accessible_ids

      socket =
        if kind == :content,
          do: assign(socket, :schedule_times, load_schedule_times(outline.all_linear_lessons)),
          else: socket

      socket
      |> assign(:tree, outline.tree)
      |> assign(:linear_lessons, linear_lessons)
      |> assign(:section, section)
      |> assign(:blocks, blocks)
      |> assign(:completed_ids, completed_ids)
      |> assign(:submissions, submissions)
      |> assign(:exam_holders, load_exam_holders(blocks, submissions, user.id, team_id))
      |> assign(:feedback_map, feedback_map)
      |> assign(:next_section_id, if(next_accessible?, do: next_section.id, else: nil))
      |> assign(:visible_blocks, calc_visible_blocks(blocks, completed_ids))
      |> assign(:overrides, overrides)
      |> assign(:block_counts, outline.block_counts)
      |> schedule_next_unlock()
    else
      _ ->
        socket
        |> put_flash(
          :warning,
          gettext("The instructor modified this content. Returning to safe zone.")
        )
        |> push_navigate(to: ~p"/learn/courses/#{course_id}")
    end
  end

  @doc """
  Real-time event handler for content updates.
  Re-evaluates access; if the current section was hidden/locked by the instructor,
  it boots the student back to the safe zone (syllabus).
  """
  @spec handle_info(atom() | tuple(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_info(:team_progress_updated, socket),
    do: {:noreply, request_refresh(socket, :progress)}

  @impl true
  def handle_info(:user_progress_updated, socket),
    do: {:noreply, request_refresh(socket, :progress)}

  @impl true
  def handle_info(:refresh_content, socket), do: {:noreply, request_refresh(socket, :content)}

  # Any team's scoring submission drops the cached board, so this fires for
  # the whole competition - a rival pulling ahead moves the standings on
  # every open player without anyone leaving their task.
  @impl true
  def handle_info(:update_leaderboard, socket),
    do: {:noreply, assign(socket, :leaderboard, load_leaderboard(socket.assigns.course))}

  @impl true
  def handle_info(:scheduled_refresh, socket) do
    {:noreply, socket |> assign(:unlock_timer, nil) |> refresh(:schedule)}
  end

  @impl true
  def handle_info(:do_refresh, socket) do
    kind = socket.assigns.refresh_pending || :progress
    {:noreply, socket |> assign(:refresh_pending, nil) |> refresh(kind)}
  end

  @impl true
  def handle_info({:submission_updated, %{status: :draft} = submission}, socket) do
    real_sub =
      Learning.get_submission(
        socket.assigns.current_user.id,
        submission.block_id,
        socket.assigns.team_id
      )

    submissions =
      if real_sub do
        Map.put(socket.assigns.submissions, submission.block_id, real_sub)
      else
        Map.delete(socket.assigns.submissions, submission.block_id)
      end

    {:noreply, assign(socket, submissions: submissions)}
  end

  @impl true
  def handle_info({:submission_updated, submission}, socket) do
    case Enum.find(socket.assigns.blocks, &(&1.id == submission.block_id)) do
      nil ->
        submissions = Map.put(socket.assigns.submissions, submission.block_id, submission)
        {:noreply, assign(socket, submissions: submissions)}

      block ->
        handle_block_submission_update(socket, block, submission)
    end
  end

  @impl true
  def handle_info(
        {AthenaWeb.StudioLive.MediaUploadComponent,
         {:saved, _block_id, "file_assignment", results}},
        socket
      ) do
    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    file_urls =
      successes
      |> Enum.map(fn {:ok, file_map} -> file_map["url"] end)
      |> Enum.reject(&is_nil/1)

    block_id = socket.assigns.active_upload_block_id

    pending = Map.get(socket.assigns, :pending_file_urls, %{})
    current = Map.get(pending, block_id, [])
    updated_pending = Map.put(pending, block_id, current ++ file_urls)

    save_file_assignment_draft(socket, block_id, updated_pending[block_id])

    socket =
      socket
      |> assign(:pending_file_urls, updated_pending)
      |> assign(:show_media_modal, false)
      |> assign(:active_upload_block_id, nil)
      |> assign(:upload_type, nil)

    socket =
      if errors != [] do
        error_count = length(errors)
        put_flash(socket, :error, gettext("Failed to save %{count} file(s)", count: error_count))
      else
        put_flash(socket, :info, gettext("File(s) ready to submit"))
      end

    {:noreply, socket}
  end

  def handle_info(
        {AthenaWeb.StudioLive.MediaUploadComponent, {:saved, block_id, "tiptap_image", results}},
        socket
      ) do
    {successes, _errors} = Enum.split_with(results, &match?({:ok, _}, &1))
    file_urls = Enum.map(successes, fn {:ok, map} -> map["url"] end) |> Enum.reject(&is_nil/1)

    socket =
      socket
      |> assign(:show_media_modal, false)
      |> assign(:active_upload_block_id, nil)
      |> assign(:upload_type, nil)

    case List.first(file_urls) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Failed to upload image"))}

      url ->
        {:noreply,
         push_event(socket, "insert_media", %{
           block_id: block_id,
           url: url,
           type: "tiptap_image"
         })}
    end
  end

  def handle_info(
        {AthenaWeb.StudioLive.MediaUploadComponent, {:saved, _block_id, _type, _results}},
        socket
      ) do
    {:noreply, socket}
  end

  def handle_info(
        {:draft_updated, %{block_id: block_id, content: content, updater_id: updater_id}},
        socket
      ) do
    if updater_id == socket.assigns.current_user.id do
      {:noreply, socket}
    else
      new_drafts = Map.put(socket.assigns.drafts || %{}, block_id, content)
      {:noreply, assign(socket, :drafts, new_drafts)}
    end
  end

  @doc false
  defp build_code_flash(submission) do
    if submission.score == 100 do
      {:info, gettext("Success! Code passed all tests.")}
    else
      {:error, gettext("Execution failed. Check the details below.")}
    end
  end

  defp gate?(block), do: block.completion_rule && block.completion_rule.type != :none

  defp all_blocks_completed?(visible_blocks, completed_ids) do
    last_block = List.last(visible_blocks)
    last_block == nil or (!gate?(last_block) or last_block.id in completed_ids)
  end

  @doc false
  defp build_draft_content(block, params, existing_draft) do
    case block.type do
      :quiz_question ->
        answer_type = block.content["answer_type"] || "plain_text"

        build_quiz_draft_content(
          block.content["question_type"],
          params,
          answer_type,
          existing_draft
        )

      :code ->
        code = get_in(params, ["answer", "code"]) || ""
        %{"type" => :code, "code" => code}

      :file_assignment ->
        %{"type" => :file_assignment, "file_urls" => []}

      _ ->
        %{}
    end
  end

  @doc false
  defp build_quiz_draft_content(question_type, params, answer_type, _existing_draft)
       when question_type in ["open", "exact_match"] do
    content = params["answer"] || ""

    if answer_type == "rich_text" do
      rich_val =
        if is_binary(content) and String.starts_with?(content, "{"),
          do: Jason.decode!(content),
          else: content

      %{"type" => :quiz_question, "rich_answer" => rich_val}
    else
      %{"type" => :quiz_question, "text_answer" => content}
    end
  end

  defp build_quiz_draft_content(_question_type, params, _answer_type, _existing_draft) do
    answer = params["answer"]

    selected =
      cond do
        is_list(answer) -> answer
        is_binary(answer) -> [answer]
        true -> []
      end

    %{"type" => :quiz_question, "selected_choices" => selected}
  end

  @doc false
  defp save_file_assignment_draft(socket, block_id, file_urls) do
    user = socket.assigns.current_user
    team_id = socket.assigns.team_id

    content = %{
      "type" => :file_assignment,
      "file_urls" => file_urls || []
    }

    Learning.save_draft(user, block_id, content, team_id)

    new_drafts = Map.put(socket.assigns.drafts || %{}, block_id, content)
    assign(socket, :drafts, new_drafts)
  end

  # Re-reads feedback for one block after a grading broadcast, so a comment
  # the instructor just left appears without a reload.
  defp refresh_block_feedback(socket, block_id) do
    feedback_map = socket.assigns[:feedback_map] || %{}

    feedback_map =
      case Learning.get_feedback_map(
             socket.assigns.current_user.id,
             [block_id],
             socket.assigns.team_id
           ) do
        %{^block_id => entry} -> Map.put(feedback_map, block_id, entry)
        _ -> Map.delete(feedback_map, block_id)
      end

    assign(socket, :feedback_map, feedback_map)
  end

  @doc "Renders the interactive course player UI."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(%{loading: true} = assigns) do
    ~H"""
    <.page_container size="narrow" class="py-10 pb-32">
      <div class="space-y-6" aria-busy="true">
        <div class="h-6 w-40 bg-base-200 rounded-sm motion-safe:animate-pulse"></div>
        <div class="h-10 w-2/3 bg-base-300 rounded-sm motion-safe:animate-pulse"></div>
        <.loading_skeleton id="player-loading" rows={3} item_class="p-6" />
      </div>
    </.page_container>
    """
  end

  def render(assigns) do
    ~H"""
    <.page_container size="narrow" class="py-10 pb-32">
      <div
        id="engagement-tracker"
        phx-hook={if @test_run, do: nil, else: "EngagementTracker"}
        data-session-id={@engagement_session_id}
      >
        <div class="flex items-center justify-between mb-12 border-b border-base-200 pb-6">
          <a
            :if={!@test_run}
            href={"/learn/courses/#{@course.id}"}
            class="inline-flex items-center gap-2 text-sm font-medium text-base-content/50 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            <span class="hidden sm:inline">{gettext("Back to Syllabus")}</span>
          </a>

          <div class="flex items-center gap-2">
            <%= if !@test_run && @prev_section_id do %>
              <.link
                navigate={~p"/learn/courses/#{@course.id}/play/#{@prev_section_id}"}
                class="btn btn-ghost btn-sm btn-square text-base-content/70 hover:text-primary"
              >
                <.icon name="hero-chevron-left" class="size-5" />
              </.link>
            <% end %>

            <button
              :if={!@test_run}
              phx-click="open_course_map"
              class="btn btn-ghost btn-sm text-base-content/70 hover:text-primary"
            >
              <.icon name="hero-map" class="size-4" />
              <span class="hidden sm:inline">{gettext("Course Map")}</span>
            </button>

            <button
              :if={!@test_run && @course.type == :competition}
              id="open-leaderboard"
              phx-click="open_leaderboard"
              class="btn btn-ghost btn-sm text-base-content/70 hover:text-primary"
            >
              <.icon name="hero-trophy" class="size-4" />
              <span class="hidden sm:inline">{gettext("Leaderboard")}</span>
            </button>

            <%= if !@test_run && @next_section_id && all_blocks_completed?(@visible_blocks, @completed_ids) do %>
              <.link
                navigate={~p"/learn/courses/#{@course.id}/play/#{@next_section_id}"}
                class="btn btn-ghost btn-sm btn-square text-base-content/70 hover:text-primary"
              >
                <.icon name="hero-chevron-right" class="size-5" />
              </.link>
            <% end %>
          </div>
        </div>

        <h1 class="text-3xl md:text-4xl font-display font-black text-base-content mb-12">
          {@section.title}
        </h1>

        <div class="space-y-10">
          <%= for block <- @visible_blocks do %>
            <% submission = Map.get(@submissions || %{}, block.id) %>

            <% sub_status_str = if submission, do: to_string(submission.status), else: "" %>
            <% sub_score = if submission, do: submission.score, else: 0 %>

            <% is_passed =
              sub_status_str == "accepted" or (sub_status_str == "graded" and sub_score == 100) %>
            <% is_pending = sub_status_str in ["pending", "processing"] %>

            <% is_review_needed = sub_status_str in ["rejected", "needs_review"] %>

            <% is_locked = is_passed or is_review_needed %>
            <% mode = if is_locked, do: :review, else: :play %>

            <%!-- A `:survey` block deliberately carries no `data-block-id`:
                  the engagement tracker finds nodes by that attribute, so its
                  absence is what keeps a feedback question out of telemetry
                  at the source. `data-engagement="off"` says so out loud for
                  anything else that walks this markup, and the server filter
                  in `engagement_batch` is the authority. --%>
            <div
              id={"block-wrapper-#{block.id}"}
              data-block-id={if block.type != :survey, do: block.id}
              data-block-type={block.type}
              data-engagement={if block.type == :survey, do: "off"}
              class="relative group animate-in slide-in-from-bottom-4 fade-in duration-500 fill-mode-both"
            >
              <div
                :if={!@test_run}
                class="hidden lg:flex absolute -left-12 top-0 flex-col gap-1 opacity-0 group-hover:opacity-100 transition-opacity"
              >
                <button
                  type="button"
                  id={"copy-link-#{block.id}"}
                  phx-hook="ClipboardCopy"
                  data-copy-text={url(~p"/go/blocks/#{block.id}")}
                  class="btn btn-ghost btn-xs btn-square"
                  title={gettext("Copy link to this block")}
                >
                  <.icon name="hero-link" class="size-4 copy-icon-default" />
                  <.icon name="hero-check" class="size-4 copy-icon-success text-success" />
                </button>
                <%!-- future per-block actions (e.g. bookmark) go here as additional siblings --%>
              </div>

              <%= case block.type do %>
                <% :quiz_question -> %>
                  <form
                    phx-submit="submit_quiz"
                    phx-change="save_draft"
                    phx-value-block_id={block.id}
                    id={"quiz-form-#{block.id}"}
                  >
                    <input type="hidden" name="block_id" value={block.id} />

                    <.content_block
                      block={block}
                      mode={mode}
                      submission={submission}
                      draft={Map.get(@drafts || %{}, block.id)}
                      user_id={@current_user.id}
                    />

                    <div class="mt-6 flex items-center justify-between">
                      <button
                        type="submit"
                        class="btn btn-primary btn-sm"
                        disabled={is_locked}
                      >
                        {cond do
                          is_review_needed -> gettext("With the instructor")
                          is_passed -> gettext("Passed")
                          submission != nil -> gettext("Retry Answer")
                          true -> gettext("Submit Answer")
                        end}
                      </button>
                    </div>
                  </form>
                <% :survey -> %>
                  <.survey_block
                    block={block}
                    state={Map.get(@survey_state || %{}, block.id)}
                    completed?={block.id in @completed_ids}
                  />
                <% type when type in [:quiz_exam, :ticket_exam] -> %>
                  <div class="relative">
                    <.content_block
                      block={block}
                      mode={mode}
                      submission={submission}
                      exam_holder={Map.get(@exam_holders || %{}, block.id)}
                    />
                  </div>
                <% :code -> %>
                  <div class="space-y-4">
                    <form
                      phx-submit="submit_code"
                      phx-change="save_draft"
                      phx-value-block_id={block.id}
                      id={"code-form-#{block.id}"}
                    >
                      <input type="hidden" name="block_id" value={block.id} />

                      <.content_block
                        block={block}
                        mode={mode}
                        submission={submission}
                        draft={Map.get(@drafts || %{}, block.id)}
                      />
                    </form>
                  </div>
                <% :file_assignment -> %>
                  <% fa_locked =
                    sub_status_str == "accepted" or (sub_status_str == "graded" and sub_score == 100) or
                      is_pending %>

                  <div class="space-y-4">
                    <form
                      phx-submit="submit_file_assignment"
                      phx-change="save_draft"
                      phx-value-block_id={block.id}
                      id={"file-assignment-form-#{block.id}"}
                    >
                      <input type="hidden" name="block_id" value={block.id} />

                      <.content_block
                        block={block}
                        mode={if fa_locked, do: :review, else: :play}
                        submission={submission}
                        pending_file_urls={@pending_file_urls}
                        draft={Map.get(@drafts || %{}, block.id)}
                      />

                      <div :if={!fa_locked} class="mt-6 flex items-center justify-between">
                        <button
                          type="submit"
                          class="btn btn-primary"
                          disabled={Map.get(@pending_file_urls, block.id, []) == []}
                        >
                          {cond do
                            submission != nil ->
                              gettext("Resubmit")

                            Map.get(@pending_file_urls, block.id, []) == [] ->
                              gettext("Select Files First")

                            true ->
                              gettext("Submit Assignment")
                          end}
                        </button>
                      </div>
                    </form>
                  </div>
                <% _ -> %>
                  <.content_block block={block} mode={:play} />
              <% end %>

              <.review_notice
                :if={is_review_needed}
                id={"review-notice-#{block.id}"}
                status={submission.status}
              />

              <.instructor_feedback
                :if={Map.has_key?(@feedback_map || %{}, block.id)}
                id={"instructor-feedback-#{block.id}"}
                entry={Map.fetch!(@feedback_map, block.id)}
              />

              <div :if={gate?(block)} class="mt-8">
                <.render_gate block={block} is_completed={block.id in @completed_ids} />
              </div>
            </div>
          <% end %>
        </div>

        <div
          :if={!@test_run && all_blocks_completed?(@visible_blocks, @completed_ids)}
          class="mt-10 pt-5 animate-in fade-in slide-in-from-bottom-8 duration-1000"
        >
          <%= if @next_section_id do %>
            <.link
              navigate={~p"/learn/courses/#{@course.id}/play/#{@next_section_id}"}
              class="btn btn-ghost"
            >
              {gettext("Next Lesson")} <.icon name="hero-arrow-right" class="size-5 ml-2" />
            </.link>
          <% else %>
            <.link navigate={~p"/learn/courses/#{@course.id}"} class="btn btn-ghost">
              {gettext("Back to Syllabus")}
            </.link>
          <% end %>
        </div>

        <div
          :if={@test_run && all_blocks_completed?(@visible_blocks, @completed_ids)}
          class="mt-10 pt-5 animate-in fade-in slide-in-from-bottom-8 duration-1000 text-sm text-base-content/60"
        >
          {gettext("Section complete. Cross-section navigation isn't available in a test run.")}
        </div>

        <.modal
          :if={@course_map_open}
          id="course-map-modal"
          show={true}
          title={gettext("Course Map")}
          on_cancel={JS.push("close_course_map")}
        >
          <div class="max-h-[60vh] overflow-y-auto -mx-6 px-6 py-2">
            <.course_map_tree
              sections={@tree}
              active_section_id={@section.id}
              course_id={@course.id}
              block_counts={@block_counts}
            />
          </div>
        </.modal>

        <.modal
          :if={@leaderboard_open}
          id="leaderboard-modal"
          show={true}
          title={gettext("Leaderboard")}
          on_cancel={JS.push("close_leaderboard")}
        >
          <div class="max-h-[60vh] overflow-y-auto -mx-6 px-6 py-2">
            <.board_table id="player-leaderboard-table" board={@leaderboard} />
          </div>
        </.modal>

        <%= if @show_media_modal do %>
          <.live_component
            module={AthenaWeb.StudioLive.MediaUploadComponent}
            id={"media-uploader-player-#{@active_upload_block_id}"}
            block_id={@active_upload_block_id}
            upload_type={@upload_type}
            current_user={@current_user}
            course_id={@course.id}
            context="student_submission"
            max_files={@max_files_for_upload}
            current_file_count={@current_file_count_for_upload}
          />
        <% end %>
      </div>
    </.page_container>
    """
  end

  def course_map_tree(assigns) do
    assigns = assign_new(assigns, :level, fn -> 0 end)
    assigns = assign_new(assigns, :block_counts, fn -> %{} end)

    ~H"""
    <div class="space-y-1">
      <div :for={section <- @sections}>
        <% has_content = Map.get(@block_counts, section.id, 0) > 0 %>
        <% is_empty_folder = not has_content and section.children != [] %>

        <%= if has_content do %>
          <.link
            navigate={~p"/learn/courses/#{@course_id}/play/#{section.id}"}
            class={[
              "w-full justify-start px-3 py-2.5 rounded-lg flex items-center gap-3 transition-all group",
              @active_section_id == section.id && "bg-primary/10 text-primary",
              @active_section_id != section.id && "hover:bg-base-200 text-base-content/70"
            ]}
            style={"padding-left: #{(@level * 1.5) + 0.75}rem;"}
          >
            <.icon
              name="hero-document-text"
              class={[
                "size-4 shrink-0 transition-colors",
                @active_section_id == section.id && "text-primary",
                @active_section_id != section.id && "text-base-content/30 group-hover:text-primary/70"
              ]}
            />
            <span class="text-sm font-medium truncate">{section.title}</span>
          </.link>
        <% else %>
          <div
            class={[
              "w-full justify-start px-3 py-2.5 rounded-lg flex items-center gap-3",
              if(is_empty_folder, do: "text-base-content/70", else: "text-base-content/40")
            ]}
            style={"padding-left: #{(@level * 1.5) + 0.75}rem;"}
          >
            <.icon
              name="hero-folder"
              class="size-4 shrink-0 text-base-content/30"
            />
            <span class="text-xs uppercase tracking-widest font-black truncate">{section.title}</span>
            <span
              :if={not is_empty_folder}
              class="text-[10px] uppercase tracking-widest ml-1 opacity-50"
            >
              {gettext("Empty")}
            </span>
          </div>
        <% end %>

        <.course_map_tree
          :if={section.children != []}
          sections={section.children}
          active_section_id={@active_section_id}
          course_id={@course_id}
          block_counts={@block_counts}
          level={@level + 1}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :status, :atom, required: true

  # Why a block the student cannot touch is closed. Rendered from the
  # submission's own status rather than from `@feedback_map`, because an
  # instructor may reject work without writing anything - and a bare
  # disabled button with no explanation is how a student ends up quietly
  # stuck, with no idea the next move is not theirs.
  defp review_notice(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "mt-6 rounded-sm border-l-2 px-4 py-3 text-sm flex items-start gap-2",
        @status == :rejected && "border-error bg-error/5 text-error",
        @status != :rejected && "border-warning bg-warning/5 text-warning"
      ]}
    >
      <.icon
        name={if @status == :rejected, do: "hero-x-circle-solid", else: "hero-clock-solid"}
        class="size-5 shrink-0"
      />
      <span class="font-bold">
        <%= if @status == :rejected do %>
          {gettext(
            "The instructor rejected this work. The block stays closed until they reopen it - message them if you think this is a mistake."
          )}
        <% else %>
          {gettext("Submitted. The instructor still has to grade this one.")}
        <% end %>
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp instructor_feedback(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "mt-6 rounded-sm border-l-2 px-4 py-3 text-sm",
        @entry.status == :rejected && "border-error bg-error/5",
        @entry.status != :rejected && "border-info bg-info/5"
      ]}
    >
      <div class={[
        "flex items-center gap-2 mb-2 font-bold",
        @entry.status == :rejected && "text-error",
        @entry.status != :rejected && "text-info"
      ]}>
        <%!-- An exam's breakdown arrives whether or not the instructor
              wrote anything, so the heading says which of the two this
              card actually is. --%>
        <.icon
          name={
            if @entry.feedback,
              do: "hero-chat-bubble-bottom-center-text",
              else: "hero-clipboard-document-list"
          }
          class="size-4"
        />
        {if @entry.feedback,
          do: gettext("Instructor Feedback"),
          else: gettext("Result Breakdown")}
      </div>

      <p :if={@entry.feedback} class="whitespace-pre-wrap leading-relaxed text-base-content/80">
        {@entry.feedback}
      </p>

      <ul :if={@entry.questions != []} class={["space-y-2", @entry.feedback && "mt-3"]}>
        <li
          :for={q <- @entry.questions}
          class="rounded-sm bg-base-100/60 border border-base-300 px-3 py-2"
        >
          <div class="flex items-center justify-between gap-2 mb-1 text-xs font-bold uppercase tracking-widest text-base-content/50">
            <span>
              {if q.number,
                do: gettext("Question %{number}", number: q.number),
                else: gettext("Question")}
            </span>
            <span>{q.score || 0} / 100</span>
          </div>
          <p
            :if={q.feedback}
            class="whitespace-pre-wrap leading-relaxed text-base-content/80"
          >
            {q.feedback}
          </p>
        </li>
      </ul>
    </div>
    """
  end

  defp render_gate(%{block: %{completion_rule: %{type: :button}}} = assigns) do
    ~H"""
    <div class="py-2 border-t border-base-200">
      <%= if @is_completed do %>
        <div></div>
      <% else %>
        <button
          phx-click="complete_gate"
          phx-value-block-id={@block.id}
          class="btn btn-primary px-10"
        >
          {@block.completion_rule.button_text || gettext("Continue")}
        </button>
      <% end %>
    </div>
    """
  end

  defp render_gate(assigns), do: ~H""

  # Unix times of every unlock/lock rule in the course (sections and
  # blocks, visible or not). Reloaded only when the course content changes.
  @doc false
  defp load_schedule_times(all_sections) do
    blocks =
      all_sections
      |> Enum.map(& &1.id)
      |> Content.list_block_headers_by_section_ids()

    (all_sections ++ blocks)
    |> Enum.map(& &1.access_rules)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&[&1.unlock_at, &1.lock_at])
    |> Enum.map(&parse_to_unix/1)
    |> Enum.reject(&is_nil/1)
  end

  # Keeps exactly one pending timer: the previous one is cancelled, so
  # refreshes don't pile up extra timers that would all fire together.
  @doc false
  defp schedule_next_unlock(socket) do
    if ref = socket.assigns.unlock_timer, do: Process.cancel_timer(ref)

    now_unix = DateTime.utc_now() |> DateTime.to_unix()

    override_times =
      (socket.assigns[:overrides] || [])
      |> Enum.flat_map(&[&1.unlock_at, &1.lock_at])
      |> Enum.map(&parse_to_unix/1)
      |> Enum.reject(&is_nil/1)

    next_unix =
      (socket.assigns.schedule_times ++ override_times)
      |> Enum.filter(&(&1 > now_unix))
      |> Enum.min(fn -> nil end)

    case next_unix do
      nil ->
        assign(socket, :unlock_timer, nil)

      target_unix ->
        raw_diff_ms = (target_unix - now_unix) * 1000 + 1000
        safe_diff_ms = min(raw_diff_ms, 86_400_000)

        assign(
          socket,
          :unlock_timer,
          Process.send_after(self(), :scheduled_refresh, safe_diff_ms)
        )
    end
  end

  defp parse_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp parse_to_unix(%NaiveDateTime{} = ndt),
    do: DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()

  defp parse_to_unix(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        DateTime.to_unix(dt)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
          _ -> nil
        end
    end
  end

  defp parse_to_unix(_), do: nil

  @doc false
  def quiz_passed?(_block, nil), do: false

  def quiz_passed?(%{completion_rule: %{type: :pass_auto_grade, min_score: min_score}}, sub) do
    sub.score >= (min_score || 0)
  end

  def quiz_passed?(_block, sub), do: sub.score == 100
end
