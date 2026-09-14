defmodule AthenaWeb.TeachingLive.TeamFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing competition teams.

  A `:type == :team`-fixed sibling of `AthenaWeb.TeachingLive.CohortFormComponent`
  - same `Athena.Learning.Cohort` changeset and `Athena.Learning` context calls,
  just without the type dropdown (a team is always a team here) and with
  "Team"/"Coach" copy instead of "Cohort"/"Instructor".
  """
  use AthenaWeb, :live_component

  alias Athena.Learning
  alias Athena.Learning.Cohort

  @impl true
  def update(%{cohort: cohort} = assigns, socket) do
    selected_instructors = extract_instructors(cohort.instructors)

    cohort_with_ids = %{
      cohort
      | instructor_ids: Enum.map(selected_instructors, & &1.id),
        type: :team
    }

    changeset = Cohort.changeset(cohort_with_ids, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:selected_instructors, selected_instructors)
     |> assign_form(changeset)}
  end

  @doc false
  defp extract_instructors(%Ecto.Association.NotLoaded{}), do: []

  defp extract_instructors(instructors) when is_list(instructors) do
    Enum.map(instructors, &format_instructor/1)
  end

  @doc false
  defp format_instructor(%{account: %{login: login}} = inst) do
    %{id: inst.id, name: "#{login} (#{inst.title})"}
  end

  defp format_instructor(inst) do
    %{id: inst.id, name: "#{gettext("Unknown")} (#{inst.title})"}
  end

  @impl true
  def handle_event("search_instructors", %{"value" => query}, socket) do
    if String.length(query) >= 2 do
      instructors = Learning.search_instructors(socket.assigns.current_user, query)

      {:noreply, assign(socket, search_query: query, search_results: instructors)}
    else
      {:noreply, assign(socket, search_query: query, search_results: [])}
    end
  end

  def handle_event("select_instructor", %{"id" => id, "name" => name}, socket) do
    selected = socket.assigns.selected_instructors

    new_selected =
      if Enum.any?(selected, &(&1.id == id)) do
        selected
      else
        selected ++ [%{id: id, name: name}]
      end

    current_params = socket.assigns.form.params || %{}

    params =
      current_params
      |> Map.put("instructor_ids", Enum.map(new_selected, & &1.id))
      |> Map.put("type", "team")

    changeset =
      socket.assigns.cohort
      |> Cohort.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:selected_instructors, new_selected)
     |> assign(:search_results, [])
     |> assign(:search_query, "")
     |> assign_form(changeset)}
  end

  def handle_event("remove_instructor", %{"id" => id}, socket) do
    new_selected = Enum.reject(socket.assigns.selected_instructors, &(&1.id == id))

    current_params = socket.assigns.form.params || %{}

    params =
      current_params
      |> Map.put("instructor_ids", Enum.map(new_selected, & &1.id))
      |> Map.put("type", "team")

    changeset =
      socket.assigns.cohort
      |> Cohort.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:selected_instructors, new_selected)
     |> assign_form(changeset)}
  end

  def handle_event("validate", %{"cohort" => cohort_params}, socket) do
    changeset =
      socket.assigns.cohort
      |> Cohort.changeset(Map.put(cohort_params, "type", "team"))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"cohort" => cohort_params}, socket) do
    save_cohort(socket, socket.assigns.action, Map.put(cohort_params, "type", "team"))
  end

  @doc false
  defp save_cohort(socket, :edit, cohort_params) do
    case Learning.update_cohort(socket.assigns.current_user, socket.assigns.cohort, cohort_params) do
      {:ok, cohort} ->
        notify_parent({:saved, cohort})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Team updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorized to update this team"))
         |> push_patch(to: socket.assigns.patch)}
    end
  end

  @doc false
  defp save_cohort(socket, :new, cohort_params) do
    case Learning.create_cohort(socket.assigns.current_user, cohort_params) do
      {:ok, cohort} ->
        notify_parent({:saved, cohort})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Team created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorized to create a team"))
         |> push_patch(to: socket.assigns.patch)}
    end
  end

  @doc false
  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  @doc false
  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form
        for={@form}
        id="team-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-6"
      >
        <.input
          field={@form[:name]}
          type="text"
          label={gettext("Team Name")}
          placeholder="e.g. Team Rocket"
        />

        <.input
          field={@form[:description]}
          type="textarea"
          label={gettext("Description (Optional)")}
          rows="3"
        />

        <div class="form-control w-full relative">
          <label class="label">
            <span class="label-text font-bold">{gettext("Assign Coaches")}</span>
          </label>

          <input type="hidden" name="cohort[instructor_ids][]" value="" />
          <%= for inst <- @selected_instructors do %>
            <input type="hidden" name="cohort[instructor_ids][]" value={inst.id} />
          <% end %>

          <div :if={@selected_instructors != []} class="flex flex-wrap gap-2 mb-3">
            <%= for inst <- @selected_instructors do %>
              <div class="badge badge-primary badge-lg gap-2 pl-3 pr-1 py-4">
                <span class="font-bold text-sm">{inst.name}</span>
                <button
                  type="button"
                  phx-click="remove_instructor"
                  phx-value-id={inst.id}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs btn-circle hover:bg-primary-focus/20 text-primary-content"
                  title={gettext("Remove")}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            <% end %>
          </div>

          <div class="relative">
            <input
              type="text"
              value={@search_query}
              phx-keyup="search_instructors"
              phx-target={@myself}
              class="input input-bordered w-full"
              placeholder={gettext("Search by login or title...")}
              autocomplete="off"
              phx-debounce="300"
            />
            <.icon
              name="hero-magnifying-glass"
              class="absolute right-3 top-3.5 size-5 text-base-content/40"
            />
          </div>

          <ul
            :if={@search_results != []}
            class="absolute top-full mt-2 left-0 w-full bg-base-100 border border-base-200 rounded-lg z-50 max-h-60 overflow-y-auto"
          >
            <%= for inst <- @search_results do %>
              <% login = if inst.account, do: inst.account.login, else: gettext("Unknown") %>
              <li
                phx-click="select_instructor"
                phx-target={@myself}
                phx-value-id={inst.id}
                phx-value-name={"#{login} (#{inst.title})"}
                class="p-3 hover:bg-primary/10 hover:text-primary cursor-pointer border-b border-base-100 last:border-0 transition-colors flex flex-col"
              >
                <span class="font-bold">{login}</span>
                <span class="text-xs opacity-70">{inst.title}</span>
              </li>
            <% end %>
          </ul>
        </div>

        <div class="flex justify-end gap-3 mt-4">
          <.button type="button" variant="ghost" phx-click={JS.patch(@patch)}>
            {gettext("Cancel")}
          </.button>
          <.button type="submit" variant="primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
