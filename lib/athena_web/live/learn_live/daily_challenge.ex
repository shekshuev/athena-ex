defmodule AthenaWeb.LearnLive.DailyChallenge do
  @moduledoc """
  Standalone "solve it here" screen for the daily challenge: one already-solved
  `code` or `quiz_question` block, presented on its own — no course chrome, no
  waterline, no section navigation, à la Hyperskill's daily review. Resolves
  the current account's own challenge (`Gamification.today_challenge/1`);
  there's no id in the route, so there's no access-control surface to get
  wrong.

  Deliberately not layered onto `Player` (course/waterline-coupled, 1600+
  lines) or `Exam`/`TicketExam` (structured around a parent exam + per-question
  child submissions, which doesn't apply here — a daily-challenge block is an
  ordinary top-level block, submitted the same way `Player` submits one).
  Submission handling below mirrors `Player`'s proven `:code`/`:quiz_question`
  logic; the one genuinely new piece is `maybe_complete/3`, which calls
  `Learning.mark_completed/3` directly instead of the generic
  `maybe_complete_from_submission/1` (which deliberately no-ops on an
  already-completed block — exactly wrong here, since every daily-challenge
  candidate is, by construction, already completed).
  """
  use AthenaWeb, :live_view

  alias Athena.{Content, Execution, Gamification, Learning}
  import AthenaWeb.BlockComponents

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_user
    {:ok, load_challenge(socket, account)}
  end

  defp load_challenge(socket, account) do
    case Gamification.today_challenge(account.id) do
      nil ->
        assign(socket, challenge: nil, block: nil, submission: nil, draft: nil, solved?: false)

      %{completed_at: %DateTime{}} = challenge ->
        assign(socket,
          challenge: challenge,
          block: nil,
          submission: nil,
          draft: nil,
          solved?: true
        )

      challenge ->
        mount_active_challenge(socket, account, challenge)
    end
  end

  defp mount_active_challenge(socket, account, challenge) do
    case Content.get_block(challenge.block_id) do
      {:ok, block} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Athena.PubSub, "submission:#{account.id}:#{block.id}")
        end

        submission =
          account.id
          |> Learning.get_latest_submissions([block.id], nil)
          |> Map.get(block.id)

        draft = Learning.get_draft(account.id, block.id, nil)

        assign(socket,
          challenge: challenge,
          block: block,
          submission: submission,
          draft: draft,
          solved?: false
        )

      {:error, _} ->
        assign(socket, challenge: nil, block: nil, submission: nil, draft: nil, solved?: false)
    end
  end

  @impl true
  def handle_event("save_draft", %{"block_id" => block_id} = params, socket) do
    block = socket.assigns.block

    if block && block.id == block_id do
      content = build_draft_content(block, params)

      case Learning.save_draft(socket.assigns.current_user, block_id, content, nil) do
        {:ok, _submission} -> {:noreply, assign(socket, :draft, content)}
        {:error, _changeset} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_draft", _params, socket), do: {:noreply, socket}

  def handle_event("update_content", %{"id" => block_id, "content" => content}, socket) do
    handle_event("save_draft", %{"block_id" => block_id, "answer" => content}, socket)
  end

  def handle_event("run_code", %{"block_id" => block_id}, socket) do
    block = socket.assigns.block
    code = extract_code_from_draft(socket.assigns.draft || %{})

    cond do
      is_nil(block) or block.id != block_id ->
        {:noreply, socket}

      String.trim(code) == "" ->
        {:noreply, put_flash(socket, :error, gettext("Please write some code first!"))}

      not Execution.runner_available?(block.content["language"]) ->
        {:noreply, put_flash(socket, :error, gettext("Runner node is not connected!"))}

      true ->
        case Learning.test_code(socket.assigns.current_user, block, code) do
          {:ok, _draft} ->
            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to enqueue code execution."))}
        end
    end
  end

  def handle_event("submit_code", params, socket) do
    block = socket.assigns.block
    code = get_in(params, ["answer", "code"]) || ""

    if block && Execution.runner_available?(block.content["language"]) do
      sub_attrs = %{
        "block_id" => block.id,
        "cohort_id" => nil,
        "status" => :pending,
        "content" => %{"type" => :code, "code" => code}
      }

      case Learning.create_submission(socket.assigns.current_user, sub_attrs) do
        {:ok, submission} -> {:noreply, assign(socket, :submission, submission)}
        {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Failed to submit code."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Runner node is not connected!"))}
    end
  end

  def handle_event("submit_quiz", params, socket) do
    block = socket.assigns.block
    answer = resolve_quiz_answer(socket, block, params["answer"])

    sub_attrs = %{
      "account_id" => socket.assigns.current_user.id,
      "block_id" => block.id,
      "cohort_id" => nil,
      "status" => :pending,
      "content" => build_submission_content(block, answer)
    }

    case Learning.create_submission(socket.assigns.current_user, sub_attrs) do
      {:ok, submission} ->
        eval_result = Learning.evaluate_sync(submission)
        {:ok, final_sub} = Learning.system_update_submission(submission, eval_result)

        socket =
          socket
          |> assign(submission: final_sub, draft: nil)
          |> maybe_complete(block, final_sub)

        {flash_type, flash_msg} =
          if final_sub.score == 100,
            do: {:info, gettext("Correct!")},
            else: {:error, gettext("Incorrect. Please try again.")}

        {:noreply, put_flash(socket, flash_type, flash_msg)}

      {:error, changeset} ->
        error_msg =
          changeset.errors
          |> Keyword.values()
          |> Enum.map_join(", ", fn {msg, _} -> msg end)

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  def handle_event(
        "reorder_matching_answer",
        %{"old_index" => old_index, "new_index" => new_index},
        socket
      ) do
    new_order = move_item(current_matching_order(socket), old_index, new_index)
    persist_matching_reorder(socket, new_order)
  end

  def handle_event("move_matching_answer_up", %{"id" => pair_id}, socket) do
    shift_matching_answer(socket, pair_id, -1)
  end

  def handle_event("move_matching_answer_down", %{"id" => pair_id}, socket) do
    shift_matching_answer(socket, pair_id, 1)
  end

  @impl true
  def handle_info({:submission_updated, %{status: :draft} = submission}, socket) do
    real_sub = Learning.get_submission(socket.assigns.current_user.id, submission.block_id, nil)
    {:noreply, assign(socket, :submission, real_sub)}
  end

  def handle_info({:submission_updated, submission}, socket) do
    block = socket.assigns.block

    socket =
      socket
      |> assign(:submission, submission)
      |> maybe_complete(block, submission)

    socket =
      case submission.status do
        :accepted ->
          put_flash(socket, :info, gettext("Success! Code passed all tests."))

        :rejected ->
          put_flash(socket, :error, gettext("Execution failed. Check the details below."))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp maybe_complete(socket, block, submission) do
    if not socket.assigns.solved? and Learning.block_solved?(block, submission) do
      {:ok, _} = Learning.mark_completed(socket.assigns.current_user.id, block.id, nil)
      assign(socket, :solved?, true)
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="narrow" class="py-10 pb-32">
      <div class="flex items-center gap-3 mb-10">
        <.link
          navigate={~p"/dashboard"}
          class="inline-flex items-center gap-2 text-sm font-medium text-base-content/50 hover:text-base-content transition-colors"
        >
          <.icon name="hero-arrow-left" class="size-4" />
          <span class="hidden sm:inline">{gettext("Back to Dashboard")}</span>
        </.link>
      </div>

      <div class="flex items-center gap-3 mb-10">
        <.icon name="hero-sparkles" class="size-8 text-primary" />
        <h1 class="text-3xl md:text-4xl font-display font-black text-base-content">
          {gettext("Daily Challenge")}
        </h1>
      </div>

      <%= cond do %>
        <% is_nil(@challenge) -> %>
          <div class="bg-base-100 border border-base-300 rounded-sm p-12 text-center">
            <.icon name="hero-moon" class="size-16 text-base-content/20 mx-auto mb-6" />
            <h3 class="text-xl font-bold text-base-content/60 mb-2">
              {gettext("No challenge available yet")}
            </h3>
            <p class="text-base-content/40">
              {gettext("Solve something in one of your courses and check back here.")}
            </p>
          </div>
        <% @solved? -> %>
          <div class="bg-success/10 border border-success/30 rounded-sm p-12 text-center">
            <.icon name="hero-check-circle" class="size-16 text-success mx-auto mb-6" />
            <h3 class="text-xl font-bold text-base-content mb-2">
              {gettext("Solved today!")}
            </h3>
            <p class="text-base-content/60">
              {gettext("Come back tomorrow for a new challenge.")}
            </p>
          </div>
        <% true -> %>
          <div class="bg-base-100 border border-base-300 rounded-sm p-6">
            <%= case @block.type do %>
              <% :quiz_question -> %>
                <form
                  phx-submit="submit_quiz"
                  phx-change="save_draft"
                  phx-value-block_id={@block.id}
                  id={"daily-challenge-quiz-#{@block.id}"}
                >
                  <input type="hidden" name="block_id" value={@block.id} />

                  <.content_block
                    block={@block}
                    mode={:play}
                    submission={@submission}
                    draft={@draft}
                    user_id={@current_user.id}
                  />

                  <div class="mt-6">
                    <button type="submit" class="btn btn-primary btn-sm">
                      {gettext("Submit Answer")}
                    </button>
                  </div>
                </form>
              <% :code -> %>
                <form
                  phx-submit="submit_code"
                  phx-change="save_draft"
                  phx-value-block_id={@block.id}
                  id={"daily-challenge-code-#{@block.id}"}
                >
                  <input type="hidden" name="block_id" value={@block.id} />

                  <.content_block
                    block={@block}
                    mode={:play}
                    submission={@submission}
                    draft={@draft}
                  />
                </form>
            <% end %>
          </div>
      <% end %>
    </.page_container>
    """
  end

  defp resolve_quiz_answer(socket, %{content: %{"question_type" => "matching"}}, _answer) do
    current_matching_order(socket)
  end

  defp resolve_quiz_answer(_socket, _block, answer), do: answer

  defp current_matching_order(socket) do
    block = socket.assigns.block
    pairs = block.content["pairs"] || []
    draft = socket.assigns.draft || %{}

    case draft["matches"] do
      list when is_list(list) and list != [] ->
        list

      _ ->
        initial_matching_order(pairs, block.id, socket.assigns.current_user.id)
    end
  end

  defp move_item(list, old_index, new_index) do
    {item, rest} = List.pop_at(list, old_index)
    List.insert_at(rest, new_index, item)
  end

  defp persist_matching_reorder(socket, new_order) do
    block = socket.assigns.block
    content = %{"type" => :quiz_question, "matches" => new_order}

    case Learning.save_draft(socket.assigns.current_user, block.id, content, nil) do
      {:ok, _submission} -> {:noreply, assign(socket, :draft, content)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  defp shift_matching_answer(socket, pair_id, delta) do
    current_order = current_matching_order(socket)

    case Enum.find_index(current_order, &(&1 == pair_id)) do
      nil ->
        {:noreply, socket}

      old_index ->
        new_index = (old_index + delta) |> max(0) |> min(length(current_order) - 1)

        if new_index == old_index do
          {:noreply, socket}
        else
          persist_matching_reorder(socket, move_item(current_order, old_index, new_index))
        end
    end
  end

  defp build_draft_content(%{type: :quiz_question} = block, params) do
    answer_type = block.content["answer_type"] || "plain_text"
    build_quiz_draft_content(block.content["question_type"], params, answer_type)
  end

  defp build_draft_content(%{type: :code}, params) do
    code = get_in(params, ["answer", "code"]) || ""
    %{"type" => :code, "code" => code}
  end

  defp build_draft_content(_block, _params), do: %{}

  defp build_quiz_draft_content(question_type, params, answer_type)
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

  defp build_quiz_draft_content(_question_type, params, _answer_type) do
    answer = params["answer"]

    selected =
      cond do
        is_list(answer) -> answer
        is_binary(answer) -> [answer]
        true -> []
      end

    %{"type" => :quiz_question, "selected_choices" => selected}
  end

  defp extract_code_from_draft(%{"code" => c}) when is_binary(c) and c != "", do: c
  defp extract_code_from_draft(%{"text_answer" => t}) when is_binary(t) and t != "", do: t

  defp extract_code_from_draft(%{"content" => %{"code" => c}}) when is_binary(c) and c != "",
    do: c

  defp extract_code_from_draft(%{"content" => %{"text_answer" => t}})
       when is_binary(t) and t != "",
       do: t

  defp extract_code_from_draft(_), do: ""

  defp build_submission_content(block, answer) do
    q_type = block.content["question_type"]
    answer_type = block.content["answer_type"] || "plain_text"
    build_submission_for_type(q_type, answer_type, answer)
  end

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
end
