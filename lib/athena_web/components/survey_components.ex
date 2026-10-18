defmodule AthenaWeb.SurveyComponents do
  @moduledoc """
  Rendering for one survey question, in each of the places a question shows
  up: the builder's configuration card, the builder's preview, the player,
  and a read-only review of what someone answered.

  `question/1` is the respondent-facing render and `question_editor/1` is the
  author-facing one. Both dispatch on `question.type`, mirroring
  `AthenaWeb.BlockComponents.content_block/1` - and, unlike it, with no
  silent fallthrough: an unhandled type raises at render rather than drawing
  a warning box nobody reads.

  ## The form contract

  Every answerable question renders its own `<form phx-change>` carrying a
  hidden `question_id` and inputs named `value[...]`, so **every type posts
  the same shape**: `%{"question_id" => id, "value" => %{...}}`, where the
  inner map is exactly what `Athena.Surveys.AnswerParams.cast/2` turns into
  an answer. One handler in the player covers all ten types, and the
  builder's preview posts what the player posts - a preview that accepted a
  value the player rejected would be worse than no preview.

  A per-question form, rather than one form for the page, is what makes
  autosave natural: answering a question saves that question.

  `:ranking` is the one exception: it is a drag-sortable list, not a form, and
  pushes `survey_rank` with the move SortableJS reports. The caller computes
  the resulting order from what it already holds - the same arrangement the
  builder uses for reordering questions.
  """

  use AthenaWeb, :html

  alias Athena.Surveys.BranchClause
  alias Athena.Surveys.QuestionTypes
  alias Athena.Surveys.QuestionTypes.Nps

  # -- respondent-facing ----------------------------------------------------

  @doc """
  Renders a question for a respondent.

  `:play` and `:preview` are the same interaction; they differ only in that a
  preview's answers are never persisted, which is the caller's business, not
  this component's. `:review` renders the given answer read-only.
  """
  attr :question, :map, required: true
  attr :mode, :atom, values: [:play, :preview, :review], default: :play
  attr :answers, :map, default: %{}
  attr :event, :string, default: "survey_answer"
  attr :target, :any, default: nil
  attr :number, :integer, default: nil
  attr :errors, :list, default: []

  def question(assigns) do
    assigns = assign(assigns, :answer, answer_for(assigns.answers, assigns.question))

    ~H"""
    <section
      id={"survey-question-#{@question.id}"}
      class="rounded-xl border border-base-300 bg-base-100 p-6 shadow-sm sm:p-8"
    >
      <header class="mb-5">
        <div class="flex items-start gap-3">
          <span
            :if={@number}
            class="mt-0.5 shrink-0 text-sm font-black tabular-nums text-base-content/40"
          >
            {@number}
          </span>
          <div class="min-w-0 flex-1">
            <div class="prose prose-sm max-w-none font-medium text-base-content sm:prose-base">
              {raw_prompt(@question)}
              <span :if={@question.required} class="ml-0.5 align-super text-error">*</span>
            </div>
            <p :if={@question.help_text} class="mt-1.5 text-sm text-base-content/60">
              {@question.help_text}
            </p>
          </div>
        </div>
      </header>

      <.answer_field
        question={@question}
        mode={@mode}
        answer={@answer}
        answers={@answers}
        event={@event}
        target={@target}
      />

      <p :for={error <- @errors} class="mt-3 text-sm text-error">{error}</p>
    </section>
    """
  end

  attr :question, :map, required: true
  attr :mode, :atom, required: true
  attr :answer, :any, default: nil
  attr :answers, :map, default: %{}
  attr :event, :string, required: true
  attr :target, :any, default: nil

  defp answer_field(%{mode: :review} = assigns), do: review_answer(assigns)

  defp answer_field(assigns) do
    case assigns.question.type do
      :single_choice -> single_choice_field(assigns)
      :multiple_choice -> multiple_choice_field(assigns)
      :dichotomous -> dichotomous_field(assigns)
      :open_text -> open_text_field(assigns)
      :numeric -> numeric_field(assigns)
      :scale -> scale_field(assigns)
      :multi_scale -> multi_scale_field(assigns)
      :matching -> matching_field(assigns)
      :ranking -> ranking_field(assigns)
      :nps -> nps_field(assigns)
    end
  end

  # One wrapper for every type, so the posted shape is uniform. `phx-submit`
  # is bound as well as `phx-change`: without it, Enter in a text field
  # reloads the page and loses the answer.
  attr :question, :map, required: true
  attr :event, :string, required: true
  attr :target, :any, default: nil
  attr :row_key, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp answer_form(assigns) do
    ~H"""
    <form
      id={"survey-answer-form-#{@question.id}#{@row_key && "-#{@row_key}"}"}
      phx-change={@event}
      phx-submit={@event}
      phx-target={@target}
      class={@class}
    >
      <input type="hidden" name="question_id" value={@question.id} />
      {render_slot(@inner_block)}
    </form>
    """
  end

  defp single_choice_field(assigns) do
    assigns = assign(assigns, :chosen, chosen_id(assigns.answer))

    ~H"""
    <.answer_form question={@question} event={@event} target={@target} class="space-y-1">
      <label
        :for={option <- options(@question)}
        class="flex cursor-pointer items-center gap-3 rounded-lg px-3 py-2.5 transition-colors hover:bg-base-200/60"
      >
        <input
          type="radio"
          name="value[choice_id]"
          value={option["id"]}
          checked={@chosen == option["id"]}
          class="radio radio-primary radio-sm"
        />
        <span class="text-sm">{option["text"]}</span>
      </label>
      <label
        :if={@question.config["other_allowed"]}
        class="flex cursor-pointer items-center gap-3 rounded-lg px-3 py-2.5 transition-colors hover:bg-base-200/60"
      >
        <input
          type="radio"
          name="value[choice_id]"
          value={QuestionTypes.other_choice_id()}
          checked={@chosen == QuestionTypes.other_choice_id()}
          class="radio radio-primary radio-sm"
        />
        <input
          type="text"
          name="value[other_text]"
          value={@answer && @answer.value_text}
          placeholder={gettext("Other…")}
          class="input input-sm input-ghost w-full max-w-xs border-b border-base-300 focus:border-primary"
        />
      </label>
    </.answer_form>
    """
  end

  defp multiple_choice_field(assigns) do
    assigns = assign(assigns, :chosen, chosen_ids(assigns.answer))

    ~H"""
    <.answer_form question={@question} event={@event} target={@target} class="space-y-1">
      <%!-- Keeps the key present when every box is cleared, so "I unchecked
            everything" arrives as an answer instead of as silence. --%>
      <input type="hidden" name="value[choice_ids][]" value="" />
      <label
        :for={option <- options(@question)}
        class="flex cursor-pointer items-center gap-3 rounded-lg px-3 py-2.5 transition-colors hover:bg-base-200/60"
      >
        <input
          type="checkbox"
          name="value[choice_ids][]"
          value={option["id"]}
          checked={option["id"] in @chosen}
          class="checkbox checkbox-primary checkbox-sm"
        />
        <span class="text-sm">{option["text"]}</span>
      </label>
      <label
        :if={@question.config["other_allowed"]}
        class="flex cursor-pointer items-center gap-3 rounded-lg px-3 py-2.5 transition-colors hover:bg-base-200/60"
      >
        <input
          type="checkbox"
          name="value[choice_ids][]"
          value={QuestionTypes.other_choice_id()}
          checked={QuestionTypes.other_choice_id() in @chosen}
          class="checkbox checkbox-primary checkbox-sm"
        />
        <input
          type="text"
          name="value[other_text]"
          value={@answer && @answer.value_text}
          placeholder={gettext("Other…")}
          class="input input-sm input-ghost w-full max-w-xs border-b border-base-300 focus:border-primary"
        />
      </label>
      <p :if={select_hint(@question)} class="px-3 pt-1 text-xs text-base-content/50">
        {select_hint(@question)}
      </p>
    </.answer_form>
    """
  end

  defp dichotomous_field(assigns) do
    assigns = assign(assigns, :chosen, chosen_id(assigns.answer))

    ~H"""
    <.answer_form question={@question} event={@event} target={@target} class="flex gap-3">
      <label
        :for={
          {id, label} <- [
            {QuestionTypes.yes_choice_id(), @question.config["yes_label"]},
            {QuestionTypes.no_choice_id(), @question.config["no_label"]}
          ]
        }
        class={[
          "flex flex-1 cursor-pointer items-center justify-center gap-2 rounded-lg border px-4 py-3 text-sm font-medium transition-all",
          if(@chosen == id,
            do: "border-primary bg-primary/10 text-primary",
            else: "border-base-300 hover:border-base-content/30"
          )
        ]}
      >
        <input
          type="radio"
          name="value[choice_id]"
          value={id}
          checked={@chosen == id}
          class="radio radio-primary radio-xs"
        />
        {label}
      </label>
    </.answer_form>
    """
  end

  defp open_text_field(assigns) do
    ~H"""
    <.answer_form question={@question} event={@event} target={@target}>
      <textarea
        :if={@question.config["multiline"]}
        name="value[text]"
        rows="4"
        maxlength={@question.config["max_length"]}
        phx-debounce="600"
        placeholder={gettext("Your answer")}
        class="textarea textarea-bordered w-full text-sm leading-relaxed"
      >{@answer && @answer.value_text}</textarea>
      <input
        :if={!@question.config["multiline"]}
        type="text"
        name="value[text]"
        value={@answer && @answer.value_text}
        maxlength={@question.config["max_length"]}
        phx-debounce="600"
        placeholder={gettext("Your answer")}
        class="input input-ghost w-full max-w-md border-b border-base-300 px-0 text-sm focus:border-primary"
      />
    </.answer_form>
    """
  end

  defp numeric_field(assigns) do
    ~H"""
    <.answer_form question={@question} event={@event} target={@target}>
      <div class="flex items-center gap-2">
        <input
          type="number"
          name="value[number]"
          value={@answer && @answer.value_numeric}
          min={@question.config["min"]}
          max={@question.config["max"]}
          step={@question.config["step"]}
          phx-debounce="600"
          class="input input-bordered w-32 text-sm tabular-nums"
        />
        <span :if={@question.config["unit"]} class="text-sm text-base-content/60">
          {@question.config["unit"]}
        </span>
      </div>
    </.answer_form>
    """
  end

  defp scale_field(assigns) do
    ~H"""
    <.answer_form question={@question} event={@event} target={@target}>
      <.scale_row
        question={@question}
        value={@answer && @answer.value_numeric}
        name="value[number]"
      />
    </.answer_form>
    """
  end

  defp multi_scale_field(assigns) do
    ~H"""
    <div class="space-y-3">
      <.answer_form
        :for={row <- rows(@question)}
        question={@question}
        event={@event}
        target={@target}
        row_key={row["id"]}
        class="rounded-lg bg-base-200/40 p-4"
      >
        <%!-- A matrix stores one answer per row, so each row posts its own
              form carrying its row id. --%>
        <input type="hidden" name="value[row_id]" value={row["id"]} />
        <p class="mb-3 text-sm font-medium">{row["text"]}</p>
        <.scale_row
          question={@question}
          value={row_value(@answers, @question, row["id"])}
          name="value[number]"
        />
      </.answer_form>
    </div>
    """
  end

  defp nps_field(assigns) do
    ~H"""
    <.answer_form question={@question} event={@event} target={@target}>
      <div class="flex flex-wrap gap-1.5">
        <label
          :for={point <- Nps.min()..Nps.max()}
          class={[
            "flex size-10 cursor-pointer items-center justify-center rounded-lg border text-sm font-bold tabular-nums transition-all",
            if(numeric_eq(@answer, point),
              do: "border-primary bg-primary text-primary-content",
              else: "border-base-300 hover:border-primary/50"
            )
          ]}
        >
          <input
            type="radio"
            name="value[number]"
            value={point}
            checked={numeric_eq(@answer, point)}
            class="sr-only"
          />
          {point}
        </label>
      </div>
      <div class="mt-2 flex justify-between text-xs text-base-content/50">
        <span>{@question.config["min_label"] || gettext("Not at all likely")}</span>
        <span>{@question.config["max_label"] || gettext("Extremely likely")}</span>
      </div>
    </.answer_form>
    """
  end

  defp matching_field(assigns) do
    ~H"""
    <.answer_form question={@question} event={@event} target={@target} class="space-y-2">
      <div
        :for={pair <- pairs(@question)}
        class="flex flex-wrap items-center gap-3 rounded-lg bg-base-200/40 px-4 py-3"
      >
        <span class="min-w-0 flex-1 text-sm">{pair["left"]}</span>
        <.icon name="hero-arrow-right" class="size-4 shrink-0 text-base-content/30" />
        <select
          name={"value[pairs][#{pair["id"]}]"}
          class="select select-bordered select-sm min-w-40 flex-1"
        >
          <option value="">{gettext("Choose…")}</option>
          <option
            :for={candidate <- right_sides(@question)}
            value={candidate["id"]}
            selected={matched?(@answer, pair["id"], candidate["id"])}
          >
            {candidate["right"]}
          </option>
        </select>
      </div>
    </.answer_form>
    """
  end

  defp ranking_field(assigns) do
    assigns = assign(assigns, :ordered, ranked_items(assigns.question, assigns.answer))

    ~H"""
    <div>
      <p class="mb-3 text-xs text-base-content/50">
        {gettext("Drag to put these in order, most important first.")}
      </p>
      <ul
        id={"survey-ranking-#{@question.id}"}
        phx-hook="Sortable"
        data-event-name="survey_rank"
        data-question-id={@question.id}
        class="space-y-2"
      >
        <li
          :for={{item, index} <- Enum.with_index(@ordered, 1)}
          id={"rank-#{@question.id}-#{item["id"]}"}
          data-id={item["id"]}
          class="flex items-center gap-3 rounded-lg border border-base-300 bg-base-100 px-4 py-3"
        >
          <span class="drag-handle cursor-grab text-base-content/30 hover:text-base-content/60">
            <.icon name="hero-bars-3" class="size-4" />
          </span>
          <span class="w-5 text-sm font-black tabular-nums text-base-content/40">{index}</span>
          <span class="min-w-0 flex-1 text-sm">{item["text"]}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :question, :map, required: true
  attr :value, :any, default: nil
  attr :name, :string, required: true

  defp scale_row(assigns) do
    ~H"""
    <div>
      <div class="flex flex-wrap gap-1.5">
        <label
          :for={{point, label} <- scale_points(@question)}
          class={[
            "flex min-w-10 flex-col items-center gap-1 rounded-lg border px-2 py-2 text-sm font-bold tabular-nums transition-all cursor-pointer",
            if(float_eq(@value, point),
              do: "border-primary bg-primary text-primary-content",
              else: "border-base-300 hover:border-primary/50"
            )
          ]}
        >
          <input
            type="radio"
            name={@name}
            value={point}
            checked={float_eq(@value, point)}
            class="sr-only"
          />
          {point}
          <span :if={label} class="text-[10px] font-normal leading-tight">{label}</span>
        </label>
      </div>
      <div
        :if={@question.config["min_label"] || @question.config["max_label"]}
        class="mt-2 flex justify-between text-xs text-base-content/50"
      >
        <span>{@question.config["min_label"]}</span>
        <span>{@question.config["max_label"]}</span>
      </div>
    </div>
    """
  end

  # -- review ---------------------------------------------------------------

  defp review_answer(%{answer: nil} = assigns) do
    ~H"""
    <p class="text-sm italic text-base-content/40">{gettext("Not answered")}</p>
    """
  end

  defp review_answer(%{answer: %{skipped: true}} = assigns) do
    ~H"""
    <p class="text-sm italic text-base-content/40">{gettext("Skipped")}</p>
    """
  end

  defp review_answer(assigns) do
    ~H"""
    <div class="text-sm">
      <%= case @question.type do %>
        <% :multi_scale -> %>
          <dl class="space-y-1.5">
            <div :for={row <- rows(@question)} class="flex items-baseline justify-between gap-4">
              <dt class="text-base-content/70">{row["text"]}</dt>
              <dd class="font-bold tabular-nums">
                {row_value(@answers, @question, row["id"]) || "–"}
              </dd>
            </div>
          </dl>
        <% :matching -> %>
          <dl class="space-y-1.5">
            <div :for={pair <- pairs(@question)} class="flex items-baseline gap-2">
              <dt class="text-base-content/70">{pair["left"]}</dt>
              <.icon name="hero-arrow-right" class="size-3.5 text-base-content/30" />
              <dd class="font-medium">{matched_label(@question, @answer, pair["id"]) || "–"}</dd>
            </div>
          </dl>
        <% :ranking -> %>
          <ol class="list-decimal space-y-1 pl-5">
            <li :for={item <- ranked_items(@question, @answer)}>{item["text"]}</li>
          </ol>
        <% _ -> %>
          <p class="font-medium">{review_label(@question, @answer)}</p>
      <% end %>
    </div>
    """
  end

  defp review_label(question, answer) do
    case QuestionTypes.measurement(question.type) do
      :text ->
        answer.value_text

      measurement when measurement in [:interval, :ratio] ->
        format_number(answer.value_numeric)

      _ ->
        answer
        |> chosen_ids()
        |> Enum.map(&choice_label(question, &1, answer))
        |> Enum.join(", ")
    end
  end

  defp choice_label(question, id, answer) do
    cond do
      id == QuestionTypes.other_choice_id() ->
        answer.value_text || gettext("Other")

      id == QuestionTypes.yes_choice_id() ->
        question.config["yes_label"]

      id == QuestionTypes.no_choice_id() ->
        question.config["no_label"]

      true ->
        case Enum.find(options(question), &(&1["id"] == id)) do
          nil -> id
          option -> option["text"]
        end
    end
  end

  defp matched_label(question, answer, left_id) do
    with right_id when is_binary(right_id) <- get_in(answer.value, ["pairs", left_id]),
         %{"right" => label} <- Enum.find(pairs(question), &(&1["id"] == right_id)) do
      label
    else
      _ -> nil
    end
  end

  # -- author-facing --------------------------------------------------------

  @doc """
  Renders the type-specific configuration for one question, inside the
  builder's question card.

  Edits are discrete events rather than one big nested form: renaming an
  option sends that option's id, adding one sends only the list it belongs
  to. Index-keyed nested params (`config[options][0][text]`) would have been
  fewer handlers, but they break the moment a list is reordered or an item is
  removed while someone is typing in another - the index that arrives no
  longer means what it meant when it was rendered.

  The three list-shaped kinds (options, matrix rows, ranking items, matching
  pairs) therefore share one trio of events - `add_list_item`,
  `remove_list_item`, `update_list_item` - keyed by the config field they
  live under.
  """
  attr :question, :map, required: true
  attr :target, :any, default: nil

  def question_editor(assigns) do
    ~H"""
    <div class="space-y-4">
      {render_config(assign(assigns, :config, @question.config))}

      <div class="flex flex-wrap items-center gap-4 border-t border-base-200 pt-4">
        <label class="flex cursor-pointer items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={@question.required}
            phx-click="toggle_required"
            phx-value-question_id={@question.id}
            phx-target={@target}
            class="toggle toggle-primary toggle-sm"
          />
          {gettext("Required")}
        </label>

        <label
          :if={@question.type in [:single_choice, :multiple_choice]}
          class="flex cursor-pointer items-center gap-2 text-sm"
        >
          <input
            type="checkbox"
            checked={!!@question.config["other_allowed"]}
            phx-click="toggle_config_flag"
            phx-value-question_id={@question.id}
            phx-value-key="other_allowed"
            phx-target={@target}
            class="toggle toggle-sm"
          />
          {gettext("Allow \"other\"")}
        </label>

        <label
          :if={@question.type in [:single_choice, :multiple_choice]}
          class="flex cursor-pointer items-center gap-2 text-sm"
        >
          <input
            type="checkbox"
            checked={!!@question.config["randomize"]}
            phx-click="toggle_config_flag"
            phx-value-question_id={@question.id}
            phx-value-key="randomize"
            phx-target={@target}
            class="toggle toggle-sm"
          />
          {gettext("Shuffle options")}
        </label>
      </div>
    </div>
    """
  end

  defp render_config(assigns) do
    case assigns.question.type do
      type when type in [:single_choice, :multiple_choice] -> choice_config(assigns)
      :dichotomous -> dichotomous_config(assigns)
      :open_text -> open_text_config(assigns)
      :numeric -> numeric_config(assigns)
      :scale -> scale_config(assigns)
      :multi_scale -> multi_scale_config(assigns)
      :matching -> matching_config(assigns)
      :ranking -> ranking_config(assigns)
      :nps -> nps_config(assigns)
    end
  end

  defp choice_config(assigns) do
    ~H"""
    <div class="space-y-2">
      <.list_item_rows
        question={@question}
        target={@target}
        list_key="options"
        fields={[{"text", gettext("Option")}]}
      />
      <.add_item_button
        question={@question}
        target={@target}
        list_key="options"
        label={gettext("Add option")}
      />
      <div :if={@question.type == :multiple_choice} class="flex gap-3 pt-2">
        <.config_number
          question={@question}
          target={@target}
          key="min_select"
          label={gettext("Choose at least")}
        />
        <.config_number
          question={@question}
          target={@target}
          key="max_select"
          label={gettext("Choose at most")}
        />
      </div>
    </div>
    """
  end

  defp dichotomous_config(assigns) do
    ~H"""
    <form phx-change="update_config" phx-target={@target} class="flex flex-wrap gap-3">
      <input type="hidden" name="question_id" value={@question.id} />
      <.input
        type="text"
        name="config[yes_label]"
        value={@config["yes_label"]}
        label={gettext("Positive label")}
        phx-debounce="500"
      />
      <.input
        type="text"
        name="config[no_label]"
        value={@config["no_label"]}
        label={gettext("Negative label")}
        phx-debounce="500"
      />
    </form>
    """
  end

  defp open_text_config(assigns) do
    ~H"""
    <form phx-change="update_config" phx-target={@target} class="flex flex-wrap items-end gap-4">
      <input type="hidden" name="question_id" value={@question.id} />
      <.input
        type="select"
        name="config[multiline]"
        value={to_string(!!@config["multiline"])}
        label={gettext("Answer size")}
        options={[{gettext("Paragraph"), "true"}, {gettext("Single line"), "false"}]}
      />
      <.input
        type="number"
        name="config[max_length]"
        value={@config["max_length"]}
        label={gettext("Character limit")}
        min="1"
        phx-debounce="500"
      />
    </form>
    """
  end

  defp numeric_config(assigns) do
    ~H"""
    <form phx-change="update_config" phx-target={@target} class="flex flex-wrap gap-3">
      <input type="hidden" name="question_id" value={@question.id} />
      <.input
        type="number"
        name="config[min]"
        value={@config["min"]}
        label={gettext("Minimum")}
        phx-debounce="500"
      />
      <.input
        type="number"
        name="config[max]"
        value={@config["max"]}
        label={gettext("Maximum")}
        phx-debounce="500"
      />
      <.input
        type="number"
        name="config[step]"
        value={@config["step"]}
        label={gettext("Step")}
        step="any"
        phx-debounce="500"
      />
      <.input
        type="text"
        name="config[unit]"
        value={@config["unit"]}
        label={gettext("Unit")}
        phx-debounce="500"
      />
    </form>
    """
  end

  defp scale_config(assigns) do
    ~H"""
    <div class="space-y-3">
      <.scale_bounds_form question={@question} config={@config} target={@target} />
      <.scale_preview question={@question} />
    </div>
    """
  end

  defp multi_scale_config(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="space-y-2">
        <p class="text-xs font-bold uppercase tracking-wide text-base-content/50">
          {gettext("Rows")}
        </p>
        <.list_item_rows
          question={@question}
          target={@target}
          list_key="rows"
          fields={[{"text", gettext("Row")}]}
        />
        <.add_item_button
          question={@question}
          target={@target}
          list_key="rows"
          label={gettext("Add row")}
        />
      </div>
      <div class="space-y-3 border-t border-base-200 pt-4">
        <p class="text-xs font-bold uppercase tracking-wide text-base-content/50">
          {gettext("Shared scale")}
        </p>
        <.scale_bounds_form question={@question} config={@config} target={@target} />
        <.scale_preview question={@question} />
      </div>
    </div>
    """
  end

  defp matching_config(assigns) do
    ~H"""
    <div class="space-y-2">
      <.list_item_rows
        question={@question}
        target={@target}
        list_key="pairs"
        fields={[{"left", gettext("Left")}, {"right", gettext("Right")}]}
      />
      <.add_item_button
        question={@question}
        target={@target}
        list_key="pairs"
        label={gettext("Add pair")}
      />
      <p class="pt-1 text-xs text-base-content/50">
        {gettext("Respondents see the right-hand items shuffled.")}
      </p>
    </div>
    """
  end

  defp ranking_config(assigns) do
    ~H"""
    <div class="space-y-2">
      <.list_item_rows
        question={@question}
        target={@target}
        list_key="items"
        fields={[{"text", gettext("Item")}]}
      />
      <.add_item_button
        question={@question}
        target={@target}
        list_key="items"
        label={gettext("Add item")}
      />
      <div class="pt-2">
        <.config_number
          question={@question}
          target={@target}
          key="max_ranked"
          label={gettext("Rank only the top")}
        />
      </div>
    </div>
    """
  end

  defp nps_config(assigns) do
    ~H"""
    <div class="space-y-3">
      <form phx-change="update_config" phx-target={@target} class="flex flex-wrap gap-3">
        <input type="hidden" name="question_id" value={@question.id} />
        <.input
          type="text"
          name="config[min_label]"
          value={@config["min_label"]}
          label={gettext("Label for 0")}
          phx-debounce="500"
        />
        <.input
          type="text"
          name="config[max_label]"
          value={@config["max_label"]}
          label={gettext("Label for 10")}
          phx-debounce="500"
        />
      </form>
      <p class="text-xs text-base-content/50">
        {gettext(
          "The 0-10 range is fixed: the promoter/passive/detractor split is only defined for it. For another range, use a scale question."
        )}
      </p>
    </div>
    """
  end

  attr :question, :map, required: true
  attr :config, :map, required: true
  attr :target, :any, default: nil

  defp scale_bounds_form(assigns) do
    ~H"""
    <form phx-change="update_config" phx-target={@target} class="flex flex-wrap gap-3">
      <input type="hidden" name="question_id" value={@question.id} />
      <.input
        type="select"
        name="config[min]"
        value={@config["min"]}
        label={gettext("From")}
        options={Enum.to_list(0..1)}
      />
      <.input
        type="select"
        name="config[max]"
        value={@config["max"]}
        label={gettext("To")}
        options={Enum.to_list(3..11)}
      />
      <.input
        type="text"
        name="config[min_label]"
        value={@config["min_label"]}
        label={gettext("Low label")}
        phx-debounce="500"
      />
      <.input
        type="text"
        name="config[max_label]"
        value={@config["max_label"]}
        label={gettext("High label")}
        phx-debounce="500"
      />
    </form>
    """
  end

  attr :question, :map, required: true

  defp scale_preview(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1.5 opacity-60">
      <span
        :for={{point, _label} <- scale_points(@question)}
        class="flex size-8 items-center justify-center rounded-md border border-base-300 text-xs font-bold tabular-nums"
      >
        {point}
      </span>
    </div>
    """
  end

  attr :question, :map, required: true
  attr :target, :any, default: nil
  attr :list_key, :string, required: true
  attr :fields, :list, required: true

  defp list_item_rows(assigns) do
    assigns = assign(assigns, :entries, List.wrap(assigns.question.config[assigns.list_key]))

    ~H"""
    <div class="space-y-2">
      <div :for={entry <- @entries} class="flex items-center gap-2">
        <form
          :for={{field, placeholder} <- @fields}
          phx-change="update_list_item"
          phx-target={@target}
          class="flex-1"
        >
          <input type="hidden" name="question_id" value={@question.id} />
          <input type="hidden" name="list_key" value={@list_key} />
          <input type="hidden" name="item_id" value={entry["id"]} />
          <input type="hidden" name="field" value={field} />
          <input
            type="text"
            name="text"
            value={entry[field]}
            placeholder={placeholder}
            phx-debounce="500"
            class="input input-ghost w-full border-b border-base-300 px-0 text-sm focus:border-primary"
          />
        </form>
        <button
          type="button"
          phx-click="remove_list_item"
          phx-value-question_id={@question.id}
          phx-value-list_key={@list_key}
          phx-value-item_id={entry["id"]}
          phx-target={@target}
          disabled={length(@entries) <= 1}
          class="btn btn-ghost btn-xs btn-square text-base-content/40 hover:text-error disabled:opacity-20"
          aria-label={gettext("Remove")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :question, :map, required: true
  attr :target, :any, default: nil
  attr :list_key, :string, required: true
  attr :label, :string, required: true

  defp add_item_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="add_list_item"
      phx-value-question_id={@question.id}
      phx-value-list_key={@list_key}
      phx-target={@target}
      class="btn btn-ghost btn-sm gap-1.5 text-primary"
    >
      <.icon name="hero-plus" class="size-4" />
      {@label}
    </button>
    """
  end

  attr :question, :map, required: true
  attr :target, :any, default: nil
  attr :key, :string, required: true
  attr :label, :string, required: true

  defp config_number(assigns) do
    ~H"""
    <form phx-change="update_config" phx-target={@target}>
      <input type="hidden" name="question_id" value={@question.id} />
      <.input
        type="number"
        name={"config[#{@key}]"}
        value={@question.config[@key]}
        label={@label}
        min="1"
        phx-debounce="500"
      />
    </form>
    """
  end

  # -- logic ----------------------------------------------------------------

  @doc """
  The branching rules attached to one question: a reorderable list of
  "if ... then ..." rows.

  Order is semantics here, not presentation - `Athena.Surveys.Flow` takes the
  first rule whose condition holds - so the list is drag-sortable and the
  position is shown.

  Operators and operand inputs are narrowed to what the *tested* question can
  actually answer (`Athena.Surveys.BranchClause.operators_for/1`). The engine
  treats a mismatched operand as false, so an editor that offered "greater
  than" on a free-text question would only help an author build a rule that
  can never match.
  """
  attr :question, :map, required: true
  attr :questions, :list, required: true
  attr :rules, :list, required: true
  attr :target, :any, default: nil

  def logic_editor(assigns) do
    ~H"""
    <div class="space-y-3">
      <ul
        :if={@rules != []}
        id={"rules-#{@question.id}"}
        phx-hook="Sortable"
        data-event-name="reorder_rules"
        data-question-id={@question.id}
        class="space-y-3"
      >
        <li
          :for={{rule, index} <- Enum.with_index(@rules, 1)}
          id={"rule-#{rule.id}"}
          data-id={rule.id}
        >
          <.rule_row
            rule={rule}
            index={index}
            question={@question}
            questions={@questions}
            target={@target}
          />
        </li>
      </ul>

      <p :if={@rules == []} class="text-sm text-base-content/50">
        {gettext("No rules. Everyone goes on to the next question.")}
      </p>

      <button
        type="button"
        phx-click="add_rule"
        phx-value-question_id={@question.id}
        phx-target={@target}
        id={"add-rule-#{@question.id}"}
        class="btn btn-ghost btn-sm gap-1.5 text-primary"
      >
        <.icon name="hero-plus" class="size-4" />
        {gettext("Add rule")}
      </button>
    </div>
    """
  end

  attr :rule, :map, required: true
  attr :index, :integer, required: true
  attr :question, :map, required: true
  attr :questions, :list, required: true
  attr :target, :any, default: nil

  defp rule_row(assigns) do
    assigns = assign(assigns, :clauses, assigns.rule.condition.clauses || [])

    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/40 p-4">
      <div class="mb-3 flex items-center gap-2">
        <span class="drag-handle cursor-grab text-base-content/30 hover:text-base-content/60">
          <.icon name="hero-bars-2" class="size-4" />
        </span>
        <span class="text-xs font-bold uppercase tracking-wide text-base-content/50">
          {gettext("Rule %{number}", number: @index)}
        </span>
        <span :if={@index == 1} class="text-xs text-base-content/40">
          {gettext("checked first")}
        </span>
        <button
          type="button"
          phx-click="delete_rule"
          phx-value-rule_id={@rule.id}
          phx-target={@target}
          id={"delete-rule-#{@rule.id}"}
          class="btn btn-ghost btn-xs btn-square ml-auto text-base-content/40 hover:text-error"
          aria-label={gettext("Delete rule")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <div class="space-y-2">
        <div :for={{clause, position} <- Enum.with_index(@clauses)} class="flex items-start gap-2">
          <span class="w-10 shrink-0 pt-2 text-xs font-bold uppercase text-base-content/40">
            <%= if position == 0 do %>
              {gettext("If")}
            <% else %>
              <button
                type="button"
                phx-click="toggle_rule_logic"
                phx-value-rule_id={@rule.id}
                phx-target={@target}
                class="link link-hover"
              >
                {logic_word(@rule.condition.logic)}
              </button>
            <% end %>
          </span>

          <.clause_form
            clause={clause}
            rule={@rule}
            questions={@questions}
            question={@question}
            target={@target}
          />

          <button
            :if={length(@clauses) > 1}
            type="button"
            phx-click="remove_clause"
            phx-value-rule_id={@rule.id}
            phx-value-clause_id={clause.id}
            phx-target={@target}
            class="btn btn-ghost btn-xs btn-square mt-1.5 text-base-content/40 hover:text-error"
            aria-label={gettext("Remove condition")}
          >
            <.icon name="hero-minus" class="size-4" />
          </button>
        </div>
      </div>

      <button
        type="button"
        phx-click="add_clause"
        phx-value-rule_id={@rule.id}
        phx-target={@target}
        class="btn btn-ghost btn-xs mt-2 gap-1 text-primary"
      >
        <.icon name="hero-plus" class="size-3.5" />
        {gettext("Add condition")}
      </button>

      <form
        phx-change="update_rule"
        phx-target={@target}
        class="mt-3 flex flex-wrap items-end gap-2 border-t border-base-300/60 pt-3"
      >
        <input type="hidden" name="rule_id" value={@rule.id} />
        <span class="pb-3 text-xs font-bold uppercase text-base-content/40">{gettext("Then")}</span>
        <.input
          type="select"
          name="action"
          value={to_string(@rule.action)}
          options={action_options()}
        />
        <.input
          :if={@rule.action == :goto_question}
          type="select"
          name="target_question_id"
          value={@rule.target_question_id}
          prompt={gettext("Choose a question")}
          options={forward_question_options(@questions, @question)}
        />
        <.input
          :if={@rule.action == :goto_page}
          type="select"
          name="target_page"
          value={@rule.target_page}
          prompt={gettext("Choose a page")}
          options={forward_page_options(@questions, @question)}
        />
      </form>
    </div>
    """
  end

  attr :clause, :map, required: true
  attr :rule, :map, required: true
  attr :questions, :list, required: true
  attr :question, :map, required: true
  attr :target, :any, default: nil

  defp clause_form(assigns) do
    tested = Enum.find(assigns.questions, &(&1.id == assigns.clause.question_id))

    assigns =
      assigns
      |> assign(:tested, tested)
      |> assign(:measurement, tested && QuestionTypes.measurement(tested.type))

    ~H"""
    <form phx-change="update_clause" phx-target={@target} class="flex min-w-0 flex-1 flex-wrap gap-2">
      <input type="hidden" name="rule_id" value={@rule.id} />
      <input type="hidden" name="clause_id" value={@clause.id} />

      <.input
        type="select"
        name="question_id"
        value={@clause.question_id}
        prompt={gettext("Choose a question")}
        options={earlier_question_options(@questions, @question)}
        class="select select-bordered select-sm min-w-40 flex-1"
      />

      <.input
        :if={@tested}
        type="select"
        name="op"
        value={to_string(@clause.op)}
        options={operator_options(@measurement)}
        class="select select-bordered select-sm"
      />

      <.clause_operand :if={@tested} clause={@clause} tested={@tested} measurement={@measurement} />
    </form>
    """
  end

  attr :clause, :map, required: true
  attr :tested, :map, required: true
  attr :measurement, :atom, required: true

  defp clause_operand(assigns) do
    assigns =
      assign(assigns, :kind, BranchClause.operand_kind(assigns.clause.op, assigns.measurement))

    ~H"""
    <%= case @kind do %>
      <% :none -> %>
      <% :number -> %>
        <.matrix_row_select :if={@tested.type == :multi_scale} clause={@clause} tested={@tested} />
        <input
          type="number"
          name="value[number]"
          value={@clause.value["number"]}
          phx-debounce="500"
          placeholder={gettext("value")}
          class="input input-bordered input-sm w-24 tabular-nums"
        />
      <% :range -> %>
        <.matrix_row_select :if={@tested.type == :multi_scale} clause={@clause} tested={@tested} />
        <input
          type="number"
          name="value[from]"
          value={@clause.value["from"]}
          phx-debounce="500"
          placeholder={gettext("from")}
          class="input input-bordered input-sm w-20 tabular-nums"
        />
        <input
          type="number"
          name="value[to]"
          value={@clause.value["to"]}
          phx-debounce="500"
          placeholder={gettext("to")}
          class="input input-bordered input-sm w-20 tabular-nums"
        />
      <% :choices -> %>
        <div class="flex min-w-0 flex-1 flex-wrap gap-2 rounded-lg border border-base-300 bg-base-100 px-3 py-2">
          <input type="hidden" name="value[choice_ids][]" value="" />
          <label
            :for={{id, label} <- clause_choices(@tested)}
            class="flex cursor-pointer items-center gap-1.5 text-xs"
          >
            <input
              type="checkbox"
              name="value[choice_ids][]"
              value={id}
              checked={id in List.wrap(@clause.value["choice_ids"])}
              class="checkbox checkbox-xs"
            />
            {label}
          </label>
        </div>
      <% :text -> %>
        <input
          type="text"
          name="value[text]"
          value={@clause.value["text"]}
          phx-debounce="500"
          placeholder={gettext("exact text")}
          class="input input-bordered input-sm min-w-32 flex-1"
        />
      <% :texts -> %>
        <input
          type="text"
          name="value[texts]"
          value={@clause.value["texts"] |> List.wrap() |> Enum.join(", ")}
          phx-debounce="500"
          placeholder={gettext("comma-separated")}
          class="input input-bordered input-sm min-w-32 flex-1"
        />
    <% end %>
    """
  end

  attr :clause, :map, required: true
  attr :tested, :map, required: true

  defp matrix_row_select(assigns) do
    ~H"""
    <%!-- A matrix stores one answer per row, so a clause testing one has to
          say which row it means. --%>
    <.input
      type="select"
      name="value[row_id]"
      value={@clause.value["row_id"]}
      prompt={gettext("Which row?")}
      options={Enum.map(rows(@tested), &{&1["text"], &1["id"]})}
      class="select select-bordered select-sm"
    />
    """
  end

  @doc """
  The logic review panel: the problems `Athena.Surveys.Flow.validate_graph/1`
  found, and a compact outline of where each answer leads.

  A text outline rather than a node graph on purpose - it is reviewable at a
  glance, works on a phone, is readable by a screen reader, and needs no new
  JavaScript. The diagram a flow chart would give is worth less than the list
  an author can actually check.
  """
  attr :issues, :list, required: true
  attr :questions, :list, required: true
  attr :branches, :map, required: true

  def logic_report(assigns) do
    ~H"""
    <div class="space-y-4">
      <div :if={@issues == []} class="flex items-center gap-2 text-sm text-success">
        <.icon name="hero-check-circle" class="size-5" />
        {gettext("The logic is sound: no loops, no dead ends, no stale references.")}
      </div>

      <ul :if={@issues != []} class="space-y-2">
        <li
          :for={issue <- @issues}
          class="flex gap-2 rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning" />
          <div>
            <p class="font-medium">{issue_title(issue.issue)}</p>
            <p class="mt-0.5 text-base-content/70">
              {issue_detail(issue, @questions)}
            </p>
          </div>
        </li>
      </ul>

      <div :if={@questions != []} class="rounded-lg bg-base-200/50 p-4">
        <p class="mb-2 text-xs font-bold uppercase tracking-wide text-base-content/50">
          {gettext("Flow outline")}
        </p>
        <ol class="space-y-1.5 text-sm">
          <li :for={{question, index} <- Enum.with_index(@questions, 1)}>
            <span class="font-medium tabular-nums text-base-content/40">{index}.</span>
            <span class="font-medium">{short_prompt(question)}</span>
            <ul class="ml-6 mt-0.5 space-y-0.5 text-xs text-base-content/60">
              <li :for={rule <- Map.get(@branches, question.id, [])}>
                {gettext("if")} {clause_summary(rule, @questions)} {gettext("then")} {action_summary(
                  rule,
                  @questions
                )}
              </li>
              <li>
                {gettext("otherwise")} {fall_through_summary(@questions, index)}
              </li>
            </ul>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  # -- logic helpers --------------------------------------------------------

  defp logic_word(:and), do: gettext("and")
  defp logic_word(:or), do: gettext("or")

  defp action_options do
    [
      {gettext("go to question"), "goto_question"},
      {gettext("go to page"), "goto_page"},
      {gettext("skip the next question"), "skip_question"},
      {gettext("end the survey"), "end_survey"}
    ]
  end

  defp operator_options(measurement) do
    measurement
    |> BranchClause.operators_for()
    |> Enum.map(&{operator_label(&1), to_string(&1)})
  end

  defp operator_label(:eq), do: gettext("is")
  defp operator_label(:neq), do: gettext("is not")
  defp operator_label(:gt), do: gettext("is more than")
  defp operator_label(:gte), do: gettext("is at least")
  defp operator_label(:lt), do: gettext("is less than")
  defp operator_label(:lte), do: gettext("is at most")
  defp operator_label(:between), do: gettext("is between")
  defp operator_label(:in), do: gettext("is one of")
  defp operator_label(:not_in), do: gettext("is none of")
  defp operator_label(:contains_any), do: gettext("includes any of")
  defp operator_label(:contains_all), do: gettext("includes all of")
  defp operator_label(:answered), do: gettext("was answered")
  defp operator_label(:not_answered), do: gettext("was not answered")

  # A clause may only test an answer the respondent has already given.
  defp earlier_question_options(questions, question) do
    questions
    |> Enum.filter(&(&1.position <= question.position))
    |> Enum.map(&{short_prompt(&1), &1.id})
  end

  # Targets may only point forward, which is what keeps the flow acyclic.
  defp forward_question_options(questions, question) do
    questions
    |> Enum.filter(&(&1.position > question.position))
    |> Enum.map(&{short_prompt(&1), &1.id})
  end

  defp forward_page_options(questions, question) do
    questions
    |> Enum.filter(&(&1.position > question.position))
    |> Enum.map(& &1.page)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{gettext("Page %{number}", number: &1 + 1), &1})
  end

  defp clause_choices(%{type: :dichotomous} = tested) do
    [
      {QuestionTypes.yes_choice_id(), tested.config["yes_label"]},
      {QuestionTypes.no_choice_id(), tested.config["no_label"]}
    ]
  end

  defp clause_choices(%{type: :ranking} = tested),
    do: Enum.map(items(tested), &{&1["id"], &1["text"]})

  defp clause_choices(tested) do
    base = Enum.map(options(tested), &{&1["id"], &1["text"]})

    if tested.config["other_allowed"] do
      base ++ [{QuestionTypes.other_choice_id(), gettext("Other")}]
    else
      base
    end
  end

  defp short_prompt(question) do
    case prompt_text(question.body) do
      "" -> gettext("Untitled question")
      text -> String.slice(text, 0, 60)
    end
  end

  defp clause_summary(rule, questions) do
    rule.condition.clauses
    |> List.wrap()
    |> Enum.map_join(" #{logic_word(rule.condition.logic)} ", fn clause ->
      tested = Enum.find(questions, &(&1.id == clause.question_id))
      name = if tested, do: short_prompt(tested), else: gettext("a deleted question")

      "#{name} #{operator_label(clause.op)} #{operand_summary(clause, tested)}"
    end)
  end

  defp operand_summary(clause, tested) do
    value = clause.value || %{}

    cond do
      Map.has_key?(value, "number") ->
        to_string(value["number"])

      Map.has_key?(value, "from") ->
        "#{value["from"]}-#{value["to"]}"

      Map.has_key?(value, "choice_ids") and tested ->
        labels = Map.new(clause_choices(tested))

        value["choice_ids"]
        |> List.wrap()
        |> Enum.map_join(", ", &Map.get(labels, &1, &1))

      Map.has_key?(value, "text") ->
        inspect(value["text"])

      Map.has_key?(value, "texts") ->
        value["texts"] |> List.wrap() |> Enum.join(", ")

      true ->
        ""
    end
  end

  defp action_summary(rule, questions) do
    case rule.action do
      :end_survey ->
        gettext("end the survey")

      :skip_question ->
        gettext("skip the next question")

      :goto_page ->
        gettext("go to page %{number}", number: rule.target_page + 1)

      :goto_question ->
        case Enum.find(questions, &(&1.id == rule.target_question_id)) do
          nil -> gettext("go to a deleted question")
          target -> gettext("go to %{question}", question: short_prompt(target))
        end
    end
  end

  defp fall_through_summary(questions, index) do
    case Enum.at(questions, index) do
      nil -> gettext("end the survey")
      next -> gettext("go to %{question}", question: short_prompt(next))
    end
  end

  defp issue_title(:all_at_once_with_rules), do: gettext("Rules cannot work on one page")
  defp issue_title(:self_target), do: gettext("A rule jumps to its own question")
  defp issue_title(:backward_target), do: gettext("A rule jumps backwards")
  defp issue_title(:dangling_target), do: gettext("A rule points at a deleted question")
  defp issue_title(:dangling_page), do: gettext("A rule points at an empty page")
  defp issue_title(:forward_clause), do: gettext("A rule tests an answer nobody has given yet")
  defp issue_title(:dangling_clause), do: gettext("A rule tests a question that is gone")

  defp issue_title(:matrix_clause_without_row),
    do: gettext("A matrix rule does not say which row")

  defp issue_title(:clause_without_operand), do: gettext("A rule is missing its value")
  defp issue_title(:cycle), do: gettext("The rules can loop")

  defp issue_detail(%{issue: :all_at_once_with_rules}, _questions) do
    gettext(
      "This survey shows every question at once, so there is no later question to send anyone to. Switch it to one question per page."
    )
  end

  defp issue_detail(issue, questions) do
    owner = Enum.find(questions, &(&1.id == issue[:question_id]))

    case owner do
      nil -> gettext("Open the question's logic to fix it.")
      question -> gettext("On: %{question}", question: short_prompt(question))
    end
  end

  # -- shared helpers -------------------------------------------------------

  @doc """
  Looks up a question's answer in the `{question_id, row_key}`-keyed map the
  player and preview both hold.
  """
  def answer_for(answers, question), do: Map.get(answers, {question.id, ""})

  defp row_value(answers, question, row_id) do
    case Map.get(answers, {question.id, row_id}) do
      nil -> nil
      answer -> answer.value_numeric
    end
  end

  defp options(question), do: List.wrap(question.config["options"])
  defp rows(question), do: List.wrap(question.config["rows"])
  defp pairs(question), do: List.wrap(question.config["pairs"])
  defp items(question), do: List.wrap(question.config["items"])

  # The right-hand sides are shown shuffled, but deterministically per
  # question: a list that reshuffled on every keystroke would be unusable.
  defp right_sides(question) do
    question |> pairs() |> Enum.sort_by(&:erlang.phash2({&1["id"], question.id}))
  end

  defp ranked_items(question, nil), do: items(question)

  defp ranked_items(question, answer) do
    all = items(question)
    by_id = Map.new(all, &{&1["id"], &1})

    ranked =
      answer.value_choice_ids
      |> List.wrap()
      |> Enum.map(&Map.get(by_id, &1))
      |> Enum.reject(&is_nil/1)

    ranked ++ Enum.reject(all, &(&1["id"] in Enum.map(ranked, fn item -> item["id"] end)))
  end

  defp chosen_id(nil), do: nil
  defp chosen_id(answer), do: answer.value_choice_ids |> List.wrap() |> List.first()

  defp chosen_ids(nil), do: []
  defp chosen_ids(answer), do: List.wrap(answer.value_choice_ids)

  defp matched?(nil, _left_id, _right_id), do: false

  defp matched?(answer, left_id, right_id),
    do: get_in(answer.value, ["pairs", left_id]) == right_id

  defp numeric_eq(nil, _point), do: false
  defp numeric_eq(answer, point), do: float_eq(answer.value_numeric, point)

  defp float_eq(nil, _point), do: false
  defp float_eq(value, point) when is_number(value), do: value / 1 == point / 1
  defp float_eq(_value, _point), do: false

  @doc """
  The points of a scale, paired with their per-point label when the author
  gave one.
  """
  def scale_points(question) do
    min = question.config["min"] || 1
    max = question.config["max"] || 5
    step = max(question.config["step"] || 1, 1)
    labels = List.wrap(question.config["point_labels"])

    min
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 <= max))
    |> Enum.with_index()
    |> Enum.map(fn {point, index} -> {point, Enum.at(labels, index)} end)
  end

  defp select_hint(question) do
    case {question.config["min_select"], question.config["max_select"]} do
      {nil, nil} -> nil
      {min, nil} -> gettext("Choose at least %{count}", count: min)
      {nil, max} -> gettext("Choose at most %{count}", count: max)
      {min, max} -> gettext("Choose between %{min} and %{max}", min: min, max: max)
    end
  end

  defp format_number(nil), do: "–"

  defp format_number(number) do
    if number == trunc(number), do: trunc(number), else: Float.round(number, 2)
  end

  # A question's prompt is a TipTap document. The builder edits it through the
  # editor hook; here it only has to be shown, and extracting its text is
  # cheaper and safer than mounting a read-only editor per question.
  defp raw_prompt(question), do: prompt_text(question.body)

  @doc """
  Plain text of a TipTap/ProseMirror document - used wherever a prompt has to
  appear as a label or an axis title rather than as rich content.

  Delegates to `Athena.Surveys.Prompt`, which the export also uses: a CSV
  header is a question's text, and two implementations of "what does this
  question say" would eventually disagree about which one a reader is looking
  at.
  """
  defdelegate prompt_text(body), to: Athena.Surveys.Prompt, as: :to_text
end
