defmodule AthenaWeb.StudioLive.Builder.InspectorComponent do
  @moduledoc """
  LiveComponent for the right sidebar in the Builder.

  Dynamically renders settings for the currently selected Section or Block.
  Allows the user to update metadata (like titles, execution modes, languages),
  visibility, and progression rules.
  """
  use AthenaWeb, :live_component

  @doc """
  Renders the inspector panel.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
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
    section_changeset = Athena.Content.Section.changeset(assigns.section, attrs)

    assigns = assign(assigns, :form, to_form(section_changeset))

    ~H"""
    <div class="flex flex-col h-full animate-in fade-in duration-200">
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
                {gettext("Public (Everyone)"), "public"},
                {gettext("Restricted (Time)"), "restricted"},
                {gettext("Hidden (Draft)"), "hidden"}
              ]}
            />

            <%= if to_string(@form[:visibility].value) == "restricted" do %>
              <div class="p-4 bg-base-200/50 rounded-xl border border-base-300 space-y-3 animate-in fade-in slide-in-from-top-2 duration-300">
                <.inputs_for :let={ar} field={@form[:access_rules]}>
                  <.input
                    type="datetime-local"
                    field={ar[:unlock_at]}
                    label={gettext("Unlock At (Optional)")}
                  />
                  <.input
                    type="datetime-local"
                    field={ar[:lock_at]}
                    label={gettext("Lock At (Optional)")}
                  />
                </.inputs_for>
              </div>
            <% end %>
          </div>
        </.form>
      </div>

      <div class="pt-4 border-t border-base-300 mt-auto pb-4 space-y-2">
        <.button
          type="button"
          phx-click="open_move_modal"
          phx-value-id={@section.id}
          class="btn btn-neutral btn-soft w-full"
        >
          <.icon name="hero-folder-arrow-down" class="size-4" />
          {gettext("Move To...")}
        </.button>

        <.button
          type="button"
          phx-click="delete_section_click"
          phx-value-id={@section.id}
          class="btn btn-error btn-soft w-full"
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

    block_changeset = Athena.Content.Block.changeset(assigns.block, attrs)

    assigns = assign(assigns, :form, to_form(block_changeset))

    ~H"""
    <div class="flex flex-col h-full animate-in fade-in duration-200">
      <div class="flex items-center gap-3 py-4 border-b border-base-300">
        <div>
          <div class="text-xs text-base-content/50 font-bold uppercase tracking-wider">
            {gettext("Type")}
          </div>
          <div class="text-sm font-medium capitalize">
            {Atom.to_string(@block.type)} {gettext("Block")}
          </div>
        </div>
      </div>

      <div class="overflow-y-auto py-4 space-y-6 flex-1">
        <.form
          for={@form}
          id={"block-inspector-form-#{@block.id}"}
          phx-change="update_block_meta"
        >
          <.input type="hidden" field={@form[:id]} />

          <%= if @block.type == :code do %>
            <div class="space-y-4 mb-6">
              <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {gettext("Execution Settings")}
              </div>
              <.input
                type="select"
                name="block[content][language]"
                value={@block.content["language"] || "python"}
                label={gettext("Programming Language")}
                options={[{"Python", "python"}, {"SQL", "sql"}, {"Elixir", "elixir"}]}
              />
              <.input
                type="select"
                name="block[content][execution_mode]"
                value={@block.content["execution_mode"] || "run"}
                label={gettext("Execution Mode")}
                options={[{"Run Code", "run"}, {"Unit Tests", "test"}]}
              />
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
                <.icon name="hero-cloud-arrow-up" class="size-4" />
                {if @block.content["url"], do: gettext("Replace File"), else: gettext("Upload File")}
              </.button>

              <%= if @block.type == :image do %>
                <.input
                  type="text"
                  name="block[content][alt]"
                  value={@block.content["alt"]}
                  label={gettext("Alt Text (for accessibility)")}
                  phx-debounce="500"
                />
              <% end %>

              <%= if @block.type == :video do %>
                <.input
                  type="text"
                  name="block[content][poster_url]"
                  value={@block.content["poster_url"]}
                  label={gettext("Poster URL (Thumbnail)")}
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
                <div class="p-4 bg-base-200/50 rounded-xl border border-base-300 animate-in fade-in slide-in-from-top-2 duration-300 mt-2">
                  <.input
                    type="text"
                    field={cr[:button_text]}
                    label={gettext("Button Text")}
                    placeholder={gettext("e.g. Understood, Continue")}
                    phx-debounce="500"
                  />
                </div>
              <% end %>

              <%= if to_string(cr[:type].value) == "pass_auto_grade" do %>
                <div class="p-4 bg-base-200/50 rounded-xl border border-base-300 animate-in fade-in slide-in-from-top-2 duration-300 mt-2">
                  <.input
                    type="number"
                    field={cr[:min_score]}
                    label={gettext("Minimum Score to Pass")}
                    placeholder="100"
                    min="0"
                    max="100"
                    phx-debounce="500"
                  />
                </div>
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
                {gettext("Public (Everyone)"), "public"},
                {gettext("Restricted (Time)"), "restricted"},
                {gettext("Hidden (Draft)"), "hidden"}
              ]}
            />

            <%= if to_string(@form[:visibility].value) == "restricted" do %>
              <div class="p-4 bg-base-200/50 rounded-xl border border-base-300 space-y-3 animate-in fade-in slide-in-from-top-2 duration-300">
                <.inputs_for :let={ar} field={@form[:access_rules]}>
                  <.input
                    type="datetime-local"
                    field={ar[:unlock_at]}
                    label={gettext("Unlock At (Optional)")}
                  />
                  <.input
                    type="datetime-local"
                    field={ar[:lock_at]}
                    label={gettext("Lock At (Optional)")}
                  />
                </.inputs_for>
              </div>
            <% end %>
          </div>
        </.form>
      </div>

      <div class="pt-4 border-t border-base-300 mt-auto pb-4 space-y-2">
        <.button type="button" class="btn btn-primary btn-soft w-full">
          <.icon name="hero-bookmark-square" class="size-4" />
          {gettext("Save to Library")}
        </.button>

        <.button
          type="button"
          phx-click="delete_block_click"
          phx-value-id={@block.id}
          class="btn btn-error btn-soft w-full"
        >
          <.icon name="hero-trash" class="size-4" />
          {gettext("Delete Block")}
        </.button>
      </div>
    </div>
    """
  end

  @doc false
  defp completion_options_for(type) when type in [:text, :image, :video] do
    [
      {gettext("None (Scroll past)"), "none"},
      {gettext("Require Button Click"), "button"}
    ]
  end

  defp completion_options_for(:attachment) do
    [
      {gettext("None (Scroll past)"), "none"},
      {gettext("Require Submission"), "submit"}
    ]
  end

  defp completion_options_for(:code) do
    [
      {gettext("None (Scroll past)"), "none"},
      {gettext("Require Submission"), "submit"},
      {gettext("Pass Auto-Grade"), "pass_auto_grade"}
    ]
  end

  defp completion_options_for(type) when type in [:quiz_question, :quiz_exam] do
    [
      {gettext("Require Submission"), "submit"},
      {gettext("Pass Auto-Grade"), "pass_auto_grade"}
    ]
  end

  defp completion_options_for(_), do: [{gettext("None"), "none"}]
end
