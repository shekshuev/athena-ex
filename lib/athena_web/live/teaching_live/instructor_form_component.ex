defmodule AthenaWeb.TeachingLive.InstructorFormComponent do
  @moduledoc """
  LiveComponent for creating and editing instructors.
  Includes an asynchronous autocomplete search for linking user accounts.
  """
  use AthenaWeb, :live_component

  alias Athena.Learning
  alias Athena.Learning.Instructor
  alias Athena.Identity

  @impl true
  def update(%{instructor: instructor} = assigns, socket) do
    changeset = Instructor.changeset(instructor, %{})

    selected_account =
      if Ecto.assoc_loaded?(instructor.account) && instructor.account do
        %{id: instructor.account.id, login: instructor.account.login}
      else
        nil
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:selected_account, selected_account)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("search_accounts", %{"value" => query}, socket) do
    if String.length(query) >= 2 do
      flop_params = %{
        "filters" => %{"0" => %{"field" => "login", "op" => "ilike_and", "value" => query}},
        "page_size" => 10
      }

      {:ok, {accounts, _}} = Identity.list_accounts(flop_params)
      {:noreply, assign(socket, search_query: query, search_results: accounts)}
    else
      {:noreply, assign(socket, search_query: query, search_results: [])}
    end
  end

  def handle_event("select_account", %{"id" => id, "login" => login}, socket) do
    current_params = socket.assigns.form.params || %{}
    params = Map.put(current_params, "owner_id", id)

    changeset =
      socket.assigns.instructor
      |> Instructor.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:selected_account, %{id: id, login: login})
     |> assign(:search_results, [])
     |> assign(:search_query, "")
     |> assign_form(changeset)}
  end

  def handle_event("clear_account", _, socket) do
    current_params = socket.assigns.form.params || %{}
    params = Map.put(current_params, "owner_id", nil)

    changeset =
      socket.assigns.instructor
      |> Instructor.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:selected_account, nil)
     |> assign_form(changeset)}
  end

  def handle_event("validate", %{"instructor" => instructor_params}, socket) do
    params_with_owner =
      if socket.assigns.selected_account do
        Map.put(instructor_params, "owner_id", socket.assigns.selected_account.id)
      else
        instructor_params
      end

    changeset =
      socket.assigns.instructor
      |> Instructor.changeset(params_with_owner)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"instructor" => instructor_params}, socket) do
    params_with_owner =
      if socket.assigns.selected_account do
        Map.put(instructor_params, "owner_id", socket.assigns.selected_account.id)
      else
        instructor_params
      end

    save_instructor(socket, socket.assigns.action, params_with_owner)
  end

  defp save_instructor(socket, :edit, instructor_params) do
    case Learning.update_instructor(socket.assigns.instructor, instructor_params) do
      {:ok, instructor} ->
        notify_parent({:saved, instructor})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Instructor updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_instructor(socket, :new, instructor_params) do
    case Learning.create_instructor(instructor_params) do
      {:ok, instructor} ->
        notify_parent({:saved, instructor})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Instructor created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form
        for={@form}
        id="instructor-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-6"
      >
        <div class="form-control w-full relative">
          <label class="label">
            <span class="label-text font-bold">{gettext("User Account")}</span>
          </label>

          <.input type="hidden" field={@form[:owner_id]} />

          <%= if @selected_account do %>
            <div class="flex items-center justify-between p-3 border border-base-300 bg-base-200/50 rounded-lg">
              <div class="flex items-center gap-2">
                <.icon name="hero-user" class="size-5 text-base-content/50" />
                <span class="font-bold">{@selected_account.login}</span>
              </div>

              <.button
                :if={@action == :new}
                type="button"
                phx-click="clear_account"
                phx-target={@myself}
                class="btn btn-ghost btn-xs btn-square text-error"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </.button>
            </div>
          <% else %>
            <div class="relative">
              <input
                type="text"
                value={@search_query}
                phx-keyup="search_accounts"
                phx-target={@myself}
                class={["input input-bordered w-full", @form[:owner_id].errors != [] && "input-error"]}
                placeholder={gettext("Search by login...")}
                autocomplete="off"
                phx-debounce="300"
              />
              <.icon
                name="hero-magnifying-glass"
                class="absolute right-3 top-3.5 size-5 text-base-content/40"
              />
            </div>

            <.error :for={msg <- @form[:owner_id].errors}>{translate_error(msg)}</.error>

            <ul
              :if={@search_results != []}
              class="absolute top-18 left-0 w-full bg-base-100 shadow-2xl border border-base-200 rounded-lg z-50 max-h-60 overflow-y-auto"
            >
              <%= for acc <- @search_results do %>
                <li
                  phx-click="select_account"
                  phx-target={@myself}
                  phx-value-id={acc.id}
                  phx-value-login={acc.login}
                  class="p-3 hover:bg-primary/10 hover:text-primary cursor-pointer border-b border-base-100 last:border-0 font-medium transition-colors"
                >
                  {acc.login}
                </li>
              <% end %>
            </ul>
          <% end %>
        </div>

        <.input
          field={@form[:title]}
          type="text"
          label={gettext("Title")}
          placeholder="e.g. Senior Professor"
        />

        <.input
          field={@form[:bio]}
          type="textarea"
          label={gettext("Biography")}
          rows="4"
        />

        <div class="flex justify-end gap-3 mt-4">
          <.button
            type="button"
            class="btn btn-ghost"
            phx-click={JS.patch(@patch)}
          >
            {gettext("Cancel")}
          </.button>
          <.button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
