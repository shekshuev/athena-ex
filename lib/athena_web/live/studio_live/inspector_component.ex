defmodule AthenaWeb.StudioLive.Builder.InspectorComponent do
  @moduledoc """
  LiveComponent for the right sidebar in the Builder.

  Dynamically renders settings for the currently selected Section or Block.
  Allows the user to update metadata (like titles, execution modes, languages),
  visibility, and progression rules.
  """
  use AthenaWeb, :live_component
  alias Athena.Content.{Section, Block}
  alias Athena.Execution

  @doc """
  Lifecycle hook: handles incoming assigns and sets defaults.
  """
  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)}
  end

  @doc """
  Renders the inspector panel.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="h-14 shrink-0 border-b border-base-300 flex items-center px-4 gap-3">
        <h3 class="font-bold text-sm uppercase tracking-wider text-base-content/70">
          {gettext("Inspector")}
        </h3>
      </div>
      <%= cond do %>
        <% @active_block -> %>
          <.block_inspector block={@active_block} />
        <% @active_section -> %>
          <.section_inspector section={@active_section} />
        <% true -> %>
          <div class="flex-1 flex items-center justify-center p-4 text-center">
            <p class="text-sm text-base-content/50 italic">
              {gettext("Select a section or block to edit settings")}
            </p>
          </div>
      <% end %>
    </div>
    """
  end

  @doc false
  @spec section_inspector(map()) :: Phoenix.LiveView.Rendered.t()
  defp section_inspector(assigns) do
    attrs = if assigns.section.access_rules, do: %{}, else: %{"access_rules" => %{}}
    section_changeset = Section.changeset(assigns.section, attrs)

    assigns = assign(assigns, :form, to_form(section_changeset))

    ~H"""
    <div class="flex flex-col flex-1 min-h-0 animate-in fade-in duration-200 px-4">
      <div class="flex items-center gap-3 py-4 border-b border-base-300">
        <div>
          <div class="text-xs text-base-content/50 font-bold uppercase tracking-wider">
            {gettext("Type")}
          </div>
          <div class="text-sm font-medium">
            {gettext("Section")}
          </div>
        </div>
      </div>

      <div class="overflow-y-auto py-4 space-y-6 flex-1">
        <.form
          for={@form}
          id={"section-inspector-form-#{@section.id}"}
          phx-change="update_section_meta"
          phx-submit="update_section_meta"
        >
          <.input type="hidden" field={@form[:id]} />

          <.input
            type="text"
            field={@form[:title]}
            label={gettext("Section Title")}
            phx-debounce="500"
          />

          <div class="divider my-4"></div>

          <div class="space-y-4">
            <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
              {gettext("Access & Visibility")}
            </div>

            <.input
              type="select"
              field={@form[:visibility]}
              label={gettext("Who can see this section?")}
              options={[
                {gettext("Enrolled Students"), "enrolled"},
                {gettext("Restricted"), "restricted"},
                {gettext("Hidden"), "hidden"}
              ]}
            />

            <.inputs_for :let={ar} field={@form[:access_rules]}>
              <div class="mt-2">
                <label class="flex items-start gap-3 cursor-pointer">
                  <input type="hidden" name={ar[:reset_waterline].name} value="false" />
                  <input
                    type="checkbox"
                    name={ar[:reset_waterline].name}
                    value="true"
                    checked={ar[:reset_waterline].value}
                    class="checkbox checkbox-sm checkbox-primary mt-0.5"
                  />
                  <div>
                    <div class="font-bold text-sm leading-none mb-1">
                      {gettext("Reset Waterline")}
                    </div>
                    <div class="text-xs text-base-content/60 leading-tight">
                      {gettext("Ignore previous locked lessons and forcefully open this section.")}
                    </div>
                  </div>
                </label>
              </div>
            </.inputs_for>
          </div>
        </.form>
      </div>

      <div class="pt-4 border-t border-base-300 mt-auto pb-4 space-y-2">
        <.button
          type="button"
          phx-click="open_move_modal"
          phx-value-id={@section.id}
          class="btn btn-outline w-full"
        >
          <.icon name="hero-folder-arrow-down" class="size-4" />
          {gettext("Move To...")}
        </.button>

        <.button
          type="button"
          phx-click="delete_section_click"
          phx-value-id={@section.id}
          class="btn btn-error btn-outline w-full"
        >
          <.icon name="hero-trash" class="size-4" />
          {gettext("Delete Section")}
        </.button>
      </div>
    </div>
    """
  end

  @doc false
  @spec block_inspector(map()) :: Phoenix.LiveView.Rendered.t()
  defp block_inspector(assigns) do
    attrs = %{}
    attrs = if assigns.block.access_rules, do: attrs, else: Map.put(attrs, "access_rules", %{})

    attrs =
      if assigns.block.completion_rule,
        do: attrs,
        else: Map.put(attrs, "completion_rule", %{"type" => "none"})

    block_changeset = Block.changeset(assigns.block, attrs)

    assigns = assign(assigns, :form, to_form(block_changeset))

    ~H"""
    <div class="flex flex-col flex-1 min-h-0 animate-in fade-in duration-200 px-4">
      <div class="flex items-center gap-3 py-4 border-b border-base-300">
        <div>
          <div class="text-xs text-base-content/50 font-bold uppercase tracking-wider">
            {gettext("Type")}
          </div>
          <div class="text-sm font-medium capitalize">
            <%= cond do %>
              <% @block.type == :quiz_exam -> %>
                {gettext("Assessment Session")} {gettext("Block")}
              <% @block.type == :ticket_exam -> %>
                {gettext("Ticket Assessment")} {gettext("Block")}
              <% true -> %>
                {Atom.to_string(@block.type) |> String.replace("_", " ")} {gettext("Block")}
            <% end %>
          </div>
        </div>
      </div>

      <div class="overflow-y-auto py-4 space-y-6 flex-1">
        <.form for={@form} id={"block-inspector-form-#{@block.id}"} phx-change="update_block_meta">
          <.input type="hidden" field={@form[:id]} />

          <%= if @block.type == :quiz_question do %>
            <div class="space-y-4 mb-6">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Question Settings")}
              </div>
              <div class="mt-4">
                <.input
                  type="number"
                  name="block[content][max_attempts]"
                  value={@block.content["max_attempts"]}
                  label={gettext("Max Attempts")}
                  placeholder={gettext("Leave empty for unlimited")}
                  min="1"
                  phx-debounce="500"
                />
              </div>

              <.input
                type="select"
                name="block[content][question_type]"
                value={@block.content["question_type"] || "open"}
                label={gettext("Question Type")}
                options={[
                  {gettext("Exact Match (CTF / Text)"), "exact_match"},
                  {gettext("Single Choice (Radio)"), "single"},
                  {gettext("Multiple Choice (Checkbox)"), "multiple"},
                  {gettext("Open Question (Essay)"), "open"}
                ]}
              />

              <.input
                type="select"
                name="block[content][answer_type]"
                value={@block.content["answer_type"] || "plain_text"}
                label={gettext("Answer Input Type")}
                options={[
                  {gettext("Plain Text"), "plain_text"},
                  {gettext("Rich Text"), "rich_text"}
                ]}
                phx-debounce="300"
              />

              <%= if @block.content["question_type"] == "exact_match" do %>
                <div class="mt-2">
                  <label class="flex items-center gap-2 cursor-pointer">
                    <input type="hidden" name="block[content][case_sensitive]" value="false" />
                    <input
                      type="checkbox"
                      name="block[content][case_sensitive]"
                      value="true"
                      checked={@block.content["case_sensitive"]}
                      class="checkbox checkbox-sm checkbox-primary mt-0.5"
                    />
                    <span class="label-text">{gettext("Case Sensitive")}</span>
                  </label>
                </div>
              <% end %>

              <div class="mt-4">
                <.input
                  type="textarea"
                  name="block[content][general_explanation]"
                  value={@block.content["general_explanation"]}
                  label={gettext("General Explanation (shown after submission)")}
                  phx-debounce="500"
                  rows="3"
                />
              </div>
            </div>
            <div class="divider my-4"></div>
          <% end %>

          <%= if @block.type == :quiz_exam do %>
            <div class="space-y-4 mb-6">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Assessment Session Configuration")}
              </div>

              <div class="flex flex-col gap-3">
                <.input
                  type="number"
                  name="block[content][count]"
                  value={@block.content["count"] || 10}
                  label={gettext("Questions Count")}
                  min="1"
                  max="100"
                />
                <.input
                  type="number"
                  name="block[content][time_limit]"
                  value={@block.content["time_limit"]}
                  label={gettext("Time Limit (sec)")}
                  placeholder={gettext("Optional")}
                  min="1"
                />
              </div>

              <div class="divider my-2"></div>
              <div class="text-xs text-base-content/50 italic mb-2">
                {gettext("Enter tags separated by commas (e.g. elixir, hard, math)")}
              </div>

              <.input
                type="text"
                name="tags_include"
                value={Enum.join(@block.content["include_tags"] || [], ", ")}
                label={gettext("Include Tags (Random pool)")}
                placeholder="advanced, tricky"
              />

              <.input
                type="text"
                name="tags_mandatory"
                value={Enum.join(@block.content["mandatory_tags"] || [], ", ")}
                label={gettext("Mandatory Tags (Must include)")}
                placeholder="elixir, basic"
              />

              <.input
                type="text"
                name="tags_exclude"
                value={Enum.join(@block.content["exclude_tags"] || [], ", ")}
                label={gettext("Exclude Tags (Do not use)")}
                placeholder="draft, deprecated"
              />
            </div>
            <div class="divider my-4"></div>
          <% end %>

          <%= if @block.type == :ticket_exam do %>
            <div class="space-y-4 mb-6">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Ticket Assessment Configuration")}
              </div>

              <div class="flex flex-col gap-3">
                <.input
                  type="number"
                  name="block[content][time_limit]"
                  value={@block.content["time_limit"]}
                  label={gettext("Time Limit (sec)")}
                  placeholder={gettext("Optional")}
                  min="1"
                  phx-debounce="500"
                />
              </div>

              <div class="flex items-center justify-between mb-2 mt-6">
                <label class="label p-0">
                  <span class="label-text font-bold text-xs uppercase text-base-content/70">
                    {gettext("Ticket Slots")}
                  </span>
                </label>
                <button
                  type="button"
                  phx-click="add_ticket_slot"
                  phx-value-id={@block.id}
                  class="btn btn-xs btn-ghost text-primary"
                >
                  <.icon name="hero-plus" class="size-3 mr-1" /> {gettext("Add Slot")}
                </button>
              </div>

              <div class="space-y-3">
                <% slots = @block.content["slots"] || [] %>
                <%= for {slot, index} <- Enum.with_index(slots) do %>
                  <div class="flex items-center gap-2">
                    <input
                      type="hidden"
                      name={"block[content][slots][#{index}][id]"}
                      value={slot["id"]}
                    />
                    <div class="flex-1">
                      <.input
                        type="text"
                        name={"block[content][slots][#{index}][tags_string]"}
                        value={Enum.join(slot["tags"] || [], ", ")}
                        placeholder={gettext("e.g. db, theory")}
                        phx-debounce="500"
                      />
                    </div>
                    <button
                      type="button"
                      phx-click="remove_ticket_slot"
                      phx-value-block_id={@block.id}
                      phx-value-slot_id={slot["id"]}
                      class="btn btn-ghost btn-sm btn-square text-error"
                      title={gettext("Remove Slot")}
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                <% end %>
                <div :if={slots == []} class="text-sm italic opacity-50 pb-2">
                  {gettext("No slots added. Add slots to specify question tags.")}
                </div>
              </div>
            </div>
            <div class="divider my-4"></div>
          <% end %>

          <%= if @block.type == :code do %>
            <div class="space-y-4 mb-6">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Execution Settings")}
              </div>

              <.input
                type="select"
                name="block[content][language]"
                value={@block.content["language"] || Execution.default_language()}
                label={gettext("Programming Language")}
                options={Execution.options()}
              />

              <%= if @block.content["language"] == "sql" do %>
                <.input
                  type="select"
                  name="block[content][body][evaluation_mode]"
                  value={get_in(@block.content, ["body", "evaluation_mode"]) || "query_result"}
                  label={gettext("Evaluation Mode")}
                  options={[
                    {gettext("Query Result"), "query_result"},
                    {gettext("State Verification"), "state_verification"}
                  ]}
                />

                <.input
                  type="number"
                  name="block[content][time_limit]"
                  value={@block.content["time_limit"] || 2.0}
                  label={gettext("Time Limit (s)")}
                  step="0.1"
                  min="0.1"
                  max="15.0"
                  phx-debounce="500"
                />
              <% else %>
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    type="number"
                    name="block[content][time_limit]"
                    value={@block.content["time_limit"] || 1.0}
                    label={gettext("Time Limit (s)")}
                    step="0.1"
                    min="0.1"
                    max="15.0"
                    phx-debounce="500"
                  />
                  <.input
                    type="number"
                    name="block[content][memory_limit]"
                    value={@block.content["memory_limit"] || 65_536}
                    label={gettext("Memory (KB)")}
                    step="1024"
                    min="16384"
                    max="524288"
                    phx-debounce="500"
                  />
                </div>
              <% end %>

              <div class="mt-2">
                <.input
                  type="number"
                  name="block[content][max_attempts]"
                  value={@block.content["max_attempts"]}
                  label={gettext("Max Attempts")}
                  placeholder={gettext("Leave empty for unlimited")}
                  min="1"
                  phx-debounce="500"
                />
              </div>
            </div>
            <div class="divider my-4"></div>
          <% end %>

          <%= if @block.type == :file_assignment do %>
            <div class="space-y-4 mb-6">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Assignment Settings")}
              </div>
              <.input
                type="number"
                name="block[content][max_files]"
                value={@block.content["max_files"] || 1}
                label={gettext("Max Files Allowed")}
                min="1"
                max="20"
                step="1"
                phx-debounce="500"
              />
              <div class="text-xs text-base-content/50 leading-relaxed -mt-2">
                {gettext("Students upload files for manual review. Allowed range: 1–20 files.")}
              </div>
            </div>
            <div class="divider my-4"></div>
          <% end %>

          <%= if @block.type in [:image, :video] do %>
            <div class="space-y-4 mb-6">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Media Settings")}
              </div>
              <.button
                type="button"
                phx-click="request_media_upload"
                phx-value-block_id={@block.id}
                phx-value-media_type={@block.type}
                class="btn btn-outline w-full mb-2"
              >
                <.icon name="hero-cloud-arrow-up" class="size-4" /> {if @block.content["url"],
                  do: gettext("Replace File"),
                  else: gettext("Upload File")}
              </.button>
              <%= if @block.type == :image do %>
                <.input
                  type="text"
                  name="block[content][alt]"
                  value={@block.content["alt"]}
                  label={gettext("Alt Text")}
                  phx-debounce="500"
                />
              <% end %>
              <%= if @block.type == :video do %>
                <.input
                  type="text"
                  name="block[content][poster_url]"
                  value={@block.content["poster_url"]}
                  label={gettext("Poster URL")}
                  phx-debounce="500"
                />
              <% end %>
            </div>
            <div class="divider my-4"></div>
          <% end %>

          <div class="space-y-4 mb-6">
            <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
              {gettext("Progression Rules")}
            </div>

            <.inputs_for :let={cr} field={@form[:completion_rule]}>
              <.input
                type="select"
                field={cr[:type]}
                label={gettext("How to unlock the next block?")}
                options={completion_options_for(@block.type)}
              />

              <%= if to_string(cr[:type].value) == "button" do %>
                <.input
                  type="text"
                  field={cr[:button_text]}
                  label={gettext("Button Text")}
                  placeholder={gettext("e.g. Understood, Continue")}
                  phx-debounce="500"
                />
              <% end %>

              <%= if to_string(cr[:type].value) == "pass_auto_grade" do %>
                <.input
                  type="number"
                  field={cr[:min_score]}
                  label={gettext("Minimum Score to Pass")}
                  placeholder="100"
                  min="0"
                  max="100"
                  phx-debounce="500"
                />
              <% end %>
            </.inputs_for>
          </div>
          <div class="divider my-4"></div>

          <div class="space-y-4">
            <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
              {gettext("Access & Visibility")}
            </div>

            <.input
              type="select"
              field={@form[:visibility]}
              label={gettext("Who can see this block?")}
              options={[
                {gettext("Inherit from Section"), "inherit"},
                {gettext("Enrolled Students"), "enrolled"},
                {gettext("Restricted"), "restricted"},
                {gettext("Hidden"), "hidden"}
              ]}
            />

            <.inputs_for :let={ar} field={@form[:access_rules]}>
              <div class="mt-2">
                <label class="flex items-start gap-3 cursor-pointer">
                  <input type="hidden" name={ar[:reset_waterline].name} value="false" />
                  <input
                    type="checkbox"
                    name={ar[:reset_waterline].name}
                    value="true"
                    checked={ar[:reset_waterline].value}
                    class="checkbox checkbox-sm checkbox-primary mt-0.5"
                  />
                  <div>
                    <div class="font-bold text-sm leading-none mb-1">
                      {gettext("Reset Waterline")}
                    </div>
                    <div class="text-xs text-base-content/60 leading-tight">
                      {gettext("Ignore previous locked lessons and forcefully open this block.")}
                    </div>
                  </div>
                </label>
              </div>
            </.inputs_for>
          </div>
        </.form>
      </div>

      <div class="pt-4 border-t border-base-300 mt-auto pb-4 space-y-2">
        <.button
          type="button"
          phx-click="open_save_library_modal"
          phx-value-id={@block.id}
          class="btn btn-primary w-full"
        >
          <.icon name="hero-bookmark-square" class="size-4" />
          {gettext("Save to Library")}
        </.button>

        <.button
          type="button"
          phx-click="delete_block_click"
          phx-value-id={@block.id}
          class="btn btn-error btn-outline w-full"
        >
          <.icon name="hero-trash" class="size-4" />
          {gettext("Delete Block")}
        </.button>
      </div>
    </div>
    """
  end

  @doc false
  defp completion_options_for(type) when type in [:text, :image, :video],
    do: [{gettext("None (Scroll past)"), "none"}, {gettext("Require Button Click"), "button"}]

  defp completion_options_for(:attachment),
    do: [{gettext("None (Scroll past)"), "none"}, {gettext("Require Button Click"), "button"}]

  defp completion_options_for(:file_assignment) do
    [
      {gettext("None (Scroll past)"), "none"},
      {gettext("Require Submission"), "submit"}
    ]
  end

  defp completion_options_for(type)
       when type in [:code, :quiz_question, :quiz_exam, :ticket_exam] do
    [
      {gettext("None (Scroll past)"), "none"},
      {gettext("Require Submission"), "submit"},
      {gettext("Pass Auto-Grade"), "pass_auto_grade"}
    ]
  end

  defp completion_options_for(_), do: [{gettext("None"), "none"}]
end
