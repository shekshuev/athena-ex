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
  """

  use AthenaWeb, :html

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
  appear as a label, an axis title or a CSV cell rather than as rich content.
  """
  def prompt_text(%{"content" => content}) when is_list(content) do
    content |> Enum.map_join(" ", &prompt_text/1) |> String.trim()
  end

  def prompt_text(%{"text" => text}) when is_binary(text), do: text
  def prompt_text(_doc), do: ""
end
