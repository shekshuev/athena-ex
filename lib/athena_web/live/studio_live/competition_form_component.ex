defmodule AthenaWeb.StudioLive.CompetitionFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing competition course metadata.

  A `:type == :competition`-fixed sibling of `AthenaWeb.StudioLive.CourseFormComponent`
  - same `Athena.Content.Course` changeset and `Athena.Content` context calls,
  just without the type dropdown (a competition is always a competition here).
  """
  use AthenaWeb, :live_component

  alias Athena.Content
  alias Athena.Content.{Course, ScoringRules}
  alias Athena.Learning
  alias Athena.TimeZones

  @impl true
  def update(%{course: course} = assigns, socket) do
    # The scoring embed is seeded on the changeset's *data* rather than
    # through `inputs_for`'s `:default`, which Ecto-backed forms reject.
    # Seeding renders the defaults without writing them: an unconfigured
    # competition only gains a rulebook once the author actually saves.
    course = %{course | type: :competition, scoring: course.scoring || %ScoringRules{}}

    changeset = Course.changeset(course, %{})

    status_options = [
      {gettext("Draft"), :draft},
      {gettext("Published"), :published},
      {gettext("Archived"), :archived}
    ]

    {:ok,
     socket
     |> assign(assigns)
     |> assign_scoring_form(changeset)
     |> assign(:status_options, status_options)
     |> assign(:mode_options, [
       {gettext("Fixed points"), :static},
       {gettext("Decaying points (CTF)"), :dynamic}
     ])
     |> assign(:curve_options, [
       {gettext("Linear"), :linear},
       {gettext("Logarithmic"), :logarithmic}
     ])
     |> assign(:tiebreaker_options, [
       {gettext("- none -"), ""},
       {gettext("Who got there first"), :time},
       {gettext("Who needed fewer attempts"), :attempts},
       {gettext("Who solved most tasks first"), :first_blood}
     ])}
  end

  # The dynamic parameters only matter in dynamic mode, and the three
  # tiebreaker selects are positional, so both are read off the changeset
  # rather than guessed from the raw params.
  defp assign_scoring_form(socket, changeset) do
    scoring = Ecto.Changeset.get_field(changeset, :scoring) |> ScoringRules.resolve()

    socket
    |> assign(:form, to_form(changeset))
    |> assign(:dynamic_scoring?, scoring.mode == :dynamic)
    |> assign(:tiebreakers, scoring.tiebreakers)
  end

  @impl true
  def handle_event("validate", %{"course" => course_params}, socket) do
    changeset =
      socket.assigns.course
      |> Course.changeset(schedule_params(course_params))
      |> Map.put(:action, :validate)

    {:noreply, assign_scoring_form(socket, changeset)}
  end

  def handle_event("save", %{"course" => course_params}, socket) do
    course_params = schedule_params(course_params)

    course_params =
      if socket.assigns.action == :new do
        Map.put(course_params, "owner_id", socket.assigns.current_user.id)
      else
        course_params
      end

    save_course(socket, socket.assigns.action, course_params)
  end

  defp save_course(socket, :edit, course_params) do
    case Content.update_course(socket.assigns.current_user, socket.assigns.course, course_params) do
      {:ok, course} ->
        notify_parent({:saved, course})
        Learning.broadcast_leaderboard_update(course.id)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Competition updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_scoring_form(socket, changeset)}
    end
  end

  defp save_course(socket, :new, course_params) do
    case Content.create_course(socket.assigns.current_user, course_params) do
      {:ok, course} ->
        notify_parent({:saved, course})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Competition created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_scoring_form(socket, changeset)}
    end
  end

  # Pins the type and turns the two wall-clock `datetime-local` values into
  # UTC before they reach the changeset.
  defp schedule_params(course_params) do
    course_params
    |> Map.put("type", "competition")
    |> TimeZones.localize_params(~w(starts_at ends_at))
    |> compact_tiebreakers()
  end

  # A `<select multiple>` submits in DOM order, not the order the author
  # clicked, so the priority is expressed as three ordered selects instead.
  # They are folded back into the list the schema stores, with the blanks
  # dropped.
  defp compact_tiebreakers(%{"scoring" => scoring} = course_params) when is_map(scoring) do
    ordered =
      ~w(tiebreaker_1 tiebreaker_2 tiebreaker_3)
      |> Enum.map(&Map.get(scoring, &1))
      |> Enum.reject(&(&1 in [nil, ""]))

    scoring =
      scoring
      |> Map.drop(~w(tiebreaker_1 tiebreaker_2 tiebreaker_3))
      |> Map.put("tiebreakers", ordered)

    Map.put(course_params, "scoring", scoring)
  end

  defp compact_tiebreakers(course_params), do: course_params

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.form
        for={@form}
        id="competition-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col h-full"
      >
        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Competition Settings")}
          </div>

          <.input
            field={@form[:title]}
            type="text"
            label={gettext("Title")}
            placeholder={gettext("e.g. Regional Programming Competition 2026")}
            required
            phx-debounce="500"
          />

          <.input
            field={@form[:code]}
            type="text"
            label={gettext("Competition Code")}
            placeholder={gettext("e.g. OLYMP-2026")}
            required={false}
            phx-debounce="500"
          />

          <.input
            field={@form[:description]}
            type="textarea"
            label={gettext("Description")}
            placeholder={gettext("Briefly describe the competition...")}
            rows="4"
            phx-debounce="500"
          />

          <.input
            field={@form[:status]}
            type="select"
            label={gettext("Visibility Status")}
            options={@status_options}
            required
          />

          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Competition Schedule")}
          </div>

          <p class="text-xs text-base-content/60 -mt-2">
            {gettext(
              "Optional. The dashboard only shows a competition from a month before it starts until a month after it ends. Leave empty to always show it."
            )}
          </p>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@form[:starts_at]}
              type="datetime-local"
              label={gettext("Starts At")}
            />
            <.input field={@form[:ends_at]} type="datetime-local" label={gettext("Ends At")} />
          </div>

          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Scoring & Ranking")}
          </div>

          <.inputs_for :let={sc} field={@form[:scoring]}>
            <div class="space-y-6">
              <.input
                field={sc[:mode]}
                type="select"
                label={gettext("Scoring Mode")}
                options={@mode_options}
              />

              <p class="text-xs text-base-content/60 -mt-4">
                <%= if @dynamic_scoring? do %>
                  {gettext(
                    "A task is worth less the more teams solve it, so finding what others could not pays more. The first team to solve it always gets full value."
                  )}
                <% else %>
                  {gettext(
                    "Every team gets the same for a task: its own point value, or 100 if it has none."
                  )}
                <% end %>
              </p>

              <div :if={@dynamic_scoring?} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={sc[:initial]}
                  type="number"
                  label={gettext("Starting Value")}
                  min="1"
                />
                <.input
                  field={sc[:minimum]}
                  type="number"
                  label={gettext("Floor Value")}
                  min="1"
                />
                <.input field={sc[:decay]} type="number" label={gettext("Decay")} min="1" />
                <.input
                  field={sc[:curve]}
                  type="select"
                  label={gettext("Decay Curve")}
                  options={@curve_options}
                />
                <.input
                  field={sc[:solve_threshold]}
                  type="number"
                  label={gettext("Counts As Solved From")}
                  min="0"
                  max="100"
                />
              </div>

              <div>
                <p class="text-sm font-bold mb-1">{gettext("Tiebreakers, in order")}</p>
                <p class="text-xs text-base-content/60 mb-3">
                  {gettext("Applied in turn when two teams end on the same score.")}
                </p>

                <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                  <%!-- Positional rather than one multi-select: a browser
                        submits a multi-select in DOM order, which cannot
                        express priority. --%>
                  <select
                    :for={{position, index} <- Enum.with_index(~w(1 2 3))}
                    id={"competition-tiebreaker-#{position}"}
                    name={"course[scoring][tiebreaker_#{position}]"}
                    class="select select-bordered w-full rounded-sm"
                  >
                    <option
                      :for={{label, value} <- @tiebreaker_options}
                      value={value}
                      selected={to_string(Enum.at(@tiebreakers, index)) == to_string(value)}
                    >
                      {label}
                    </option>
                  </select>
                </div>

                <%!-- The positional selects are hand-written, so their
                      field's errors need showing by hand too. --%>
                <.error :for={msg <- Enum.map(sc[:tiebreakers].errors, &translate_error/1)}>
                  {msg}
                </.error>
              </div>

              <.input
                field={sc[:disqualify_on_rejected]}
                type="checkbox"
                label={gettext("Disqualify a team once any of its work is rejected")}
              />
            </div>
          </.inputs_for>
        </div>

        <div class="shrink-0 p-6 border-t border-base-200 bg-base-100 flex justify-end gap-3">
          <.button variant="ghost" patch={@patch}>{gettext("Cancel")}</.button>
          <.button type="submit" variant="primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
