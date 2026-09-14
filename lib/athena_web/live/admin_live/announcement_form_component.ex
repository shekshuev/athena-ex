defmodule AthenaWeb.AdminLive.AnnouncementFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing announcements.

  The "Global" scope option is only offered to accounts holding the
  "admin" bypass permission; everyone else may only pick from the cohorts
  they instruct (`Athena.Learning.list_postable_cohort_options/1`).
  Authorization is ultimately enforced by `Athena.Announcements`, not by
  this component — hiding options here is a UX convenience, not a
  security boundary.
  """
  use AthenaWeb, :live_component

  alias Athena.{Announcements, Learning}
  alias Athena.Announcements.Announcement

  @impl true
  def update(%{announcement: announcement} = assigns, socket) do
    changeset = Announcement.changeset(announcement, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:cohort_options, Learning.list_postable_cohort_options(assigns.current_user))
     |> assign(:show_global_option?, "admin" in assigns.current_user.role.permissions)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"announcement" => params}, socket) do
    changeset =
      socket.assigns.announcement
      |> Announcement.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"announcement" => params}, socket) do
    save_announcement(socket, socket.assigns.action, params)
  end

  defp save_announcement(socket, :new, params) do
    case Announcements.create_announcement(socket.assigns.current_user, params) do
      {:ok, announcement} ->
        notify_parent({:saved, announcement})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Announcement created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You don't have permission to post to this cohort."))
         |> push_patch(to: socket.assigns.patch)}
    end
  end

  defp save_announcement(socket, :edit, params) do
    case Announcements.update_announcement(
           socket.assigns.current_user,
           socket.assigns.announcement,
           params
         ) do
      {:ok, announcement} ->
        notify_parent({:saved, announcement})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Announcement updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You don't have permission to post to this cohort."))
         |> push_patch(to: socket.assigns.patch)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp scope_options(show_global_option?) do
    cohort_option = {gettext("Cohort"), "cohort"}

    if show_global_option?,
      do: [{gettext("Global"), "global"}, cohort_option],
      else: [cohort_option]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.form
        for={@form}
        id="announcement-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col h-full"
      >
        <div class="flex-1 overflow-y-auto p-6 space-y-4">
          <.input field={@form[:title]} type="text" label={gettext("Title")} required autofocus />

          <.input
            field={@form[:body]}
            type="textarea"
            label={gettext("Body")}
            rows="6"
            required
          />

          <.input
            field={@form[:scope]}
            type="select"
            label={gettext("Audience")}
            options={scope_options(@show_global_option?)}
            prompt={gettext("Select audience")}
          />

          <.input
            :if={to_string(@form[:scope].value) == "cohort"}
            field={@form[:cohort_id]}
            type="select"
            label={gettext("Cohort")}
            options={@cohort_options}
            prompt={gettext("Select cohort")}
          />
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
