defmodule AthenaWeb.LinkFormComponent do
  @moduledoc """
  Modal form for inserting/editing a hyperlink inside a TipTap editor
  (URL + display text, same as inserting any ordinary hyperlink - blocks
  have no title to look up).

  The editor lives in a `phx-update="ignore"` container, so the server has
  no visibility into its live cursor/selection. The client reads the
  current link's href (if the cursor is inside one) and the selected text
  before opening this modal, and passes them in as `href`/`text`. On
  submit, the host LiveView (`builder.ex`, `library_editor.ex`,
  `announcement_form.ex`) receives `{:apply_link, block_id, href, text}` or
  `{:remove_link, block_id}` and pushes it back down to the one TipTap
  instance identified by `block_id`.
  """
  use AthenaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(%{"href" => assigns.href, "text" => assigns.text}, as: "link"))}
  end

  @impl true
  def handle_event("validate", %{"link" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: "link"))}
  end

  def handle_event("save", %{"link" => %{"href" => href, "text" => text}}, socket) do
    case String.trim(href) do
      "" ->
        {:noreply,
         assign(
           socket,
           :form,
           to_form(%{"href" => href, "text" => text},
             as: "link",
             errors: [href: {gettext("Enter a URL"), []}]
           )
         )}

      href ->
        notify_parent({:apply_link, socket.assigns.block_id, href, text})
        {:noreply, socket}
    end
  end

  def handle_event("remove_link", _params, socket) do
    notify_parent({:remove_link, socket.assigns.block_id})
    {:noreply, socket}
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.form for={@form} id="link-form" phx-target={@myself} phx-change="validate" phx-submit="save">
        <div class="space-y-4">
          <.input
            field={@form[:href]}
            type="text"
            label={gettext("URL")}
            placeholder="https://example.com"
            autofocus
            required
          />
          <.input
            field={@form[:text]}
            type="text"
            label={gettext("Text")}
            placeholder={gettext("Link text")}
          />
        </div>
      </.form>
      <div class="modal-action">
        <.button
          :if={@href}
          type="button"
          variant="ghost"
          class="text-error mr-auto"
          phx-click="remove_link"
          phx-target={@myself}
        >
          {gettext("Remove link")}
        </.button>
        <.button type="button" variant="ghost" phx-click={@on_cancel}>
          {gettext("Cancel")}
        </.button>
        <.button type="submit" form="link-form" variant="primary">
          {gettext("Save")}
        </.button>
      </div>
    </div>
    """
  end
end
