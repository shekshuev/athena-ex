defmodule AthenaWeb.StudioLive.CourseEnrollmentComponent do
  @moduledoc """
  LiveComponent for subscribing individual students to a course,
  independent of any cohort/group enrollment.
  """
  use AthenaWeb, :live_component

  alias Athena.Identity
  alias Athena.Learning

  @impl true
  def update(%{course: course} = assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(search_form: to_form(%{"query" => ""}))
      |> assign(search_results: [])
      |> assign(error_msg: nil)
      |> load_enrollments(course)

    {:ok, socket}
  end

  defp load_enrollments(socket, course) do
    enrollments =
      socket.assigns.current_user
      |> Learning.list_account_enrollments(course.id)
      |> Enum.reject(&(&1.status == :dropped))
      |> Enum.sort_by(&(&1.account && &1.account.login))

    assign(socket, enrollments: enrollments)
  end

  @impl true
  def handle_event("search_users", %{"query" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        Identity.search_accounts_by_login(socket.assigns.current_user, query, 5)
      else
        []
      end

    {:noreply,
     socket
     |> assign(search_form: to_form(%{"query" => query}))
     |> assign(search_results: results)}
  end

  def handle_event("add_enrollment", %{"account_id" => account_id}, socket) do
    case Learning.enroll_account(
           socket.assigns.current_user,
           account_id,
           socket.assigns.course.id
         ) do
      {:ok, _enrollment} ->
        {:noreply,
         socket
         |> load_enrollments(socket.assigns.course)
         |> assign(search_form: to_form(%{"query" => ""}), search_results: [], error_msg: nil)
         |> put_flash(:info, gettext("Student enrolled successfully."))}

      {:error, :forbidden} ->
        {:noreply, assign(socket, error_msg: gettext("Permission denied."))}

      {:error, msg} when is_binary(msg) ->
        {:noreply, assign(socket, error_msg: msg)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error_msg: gettext("This student is already enrolled."))}
    end
  end

  def handle_event("remove_enrollment", %{"id" => id}, socket) do
    enrollment = Enum.find(socket.assigns.enrollments, &(&1.id == id))

    case enrollment && Learning.delete_enrollment(socket.assigns.current_user, enrollment) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_enrollments(socket.assigns.course)
         |> put_flash(:info, gettext("Access revoked."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to revoke access."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6" id={@id}>
      <div class="relative">
        <.form for={@search_form} phx-change="search_users" phx-target={@myself}>
          <.input
            field={@search_form[:query]}
            type="text"
            placeholder={gettext("Search user by login to enroll...")}
            autocomplete="off"
            phx-debounce="300"
            class="input input-bordered w-full"
          />
        </.form>

        <ul
          :if={@search_results != []}
          class="absolute z-50 w-full mt-1 bg-base-100 border border-base-300 rounded-box max-h-60 overflow-y-auto"
        >
          <li
            :for={user <- @search_results}
            class="flex items-center justify-between p-3 hover:bg-base-200"
          >
            <span class="font-bold">{user.login}</span>
            <.button
              type="button"
              class="btn btn-xs btn-ghost text-primary"
              phx-click="add_enrollment"
              phx-value-account_id={user.id}
              phx-target={@myself}
            >
              + {gettext("Enroll")}
            </.button>
          </li>
        </ul>
      </div>

      <p :if={@error_msg} class="text-sm text-error">{@error_msg}</p>

      <div class="divider text-xs font-bold uppercase text-base-content/50">
        {gettext("Enrolled Students")}
      </div>

      <div class="space-y-2 max-h-80 overflow-y-auto">
        <p :if={@enrollments == []} class="text-sm text-base-content/60">
          {gettext("No individually enrolled students yet.")}
        </p>

        <div
          :for={enrollment <- @enrollments}
          class="flex items-center justify-between p-3 bg-base-200 rounded-box"
        >
          <span class="font-bold">
            {if enrollment.account, do: enrollment.account.login, else: gettext("Unknown")}
          </span>
          <.button
            type="button"
            class="btn btn-xs btn-ghost text-error"
            phx-click="remove_enrollment"
            phx-value-id={enrollment.id}
            phx-target={@myself}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.button>
        </div>
      </div>
    </div>
    """
  end
end
