defmodule AthenaWeb.FileLive.FileShareComponent do
  @moduledoc """
  LiveComponent for managing a personal file's visibility and sharing
  access — one-to-one with `AthenaWeb.StudioLive.CourseShareComponent`,
  minus the reader/writer role (a shared file has no "edit" action, only
  "can see it or not").
  """
  use AthenaWeb, :live_component

  alias Athena.Media
  alias Athena.Identity

  @impl true
  def update(%{file: file} = assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(search_form: to_form(%{"query" => ""}))
      |> assign(search_results: [])
      |> assign(share_to_remove: nil)
      |> load_shares(file)

    {:ok, socket}
  end

  defp load_shares(socket, file) do
    shares = Media.list_file_shares(file)
    account_ids = Enum.map(shares, & &1.account_id)
    accounts_map = Identity.get_accounts_map(account_ids)

    enriched_shares =
      shares
      |> Enum.map(fn share ->
        account = Map.get(accounts_map, share.account_id)

        %{
          account_id: share.account_id,
          login: if(account, do: account.login, else: "Unknown"),
          name: if(account, do: Identity.display_name(account), else: "Unknown")
        }
      end)
      |> Enum.sort_by(& &1.name)

    assign(socket, shares: enriched_shares, is_public: file.is_public)
  end

  @impl true
  def handle_event("toggle_public", %{"is_public" => is_public_str}, socket) do
    is_public = is_public_str == "true"

    case Media.toggle_file_public(socket.assigns.current_user, socket.assigns.file, is_public) do
      {:ok, updated_file} ->
        send(self(), {__MODULE__, {:updated, updated_file}})
        {:noreply, assign(socket, is_public: updated_file.is_public)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update visibility."))}
    end
  end

  def handle_event("search_users", %{"query" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        Identity.search_messageable_accounts(socket.assigns.current_user, query, 5)
      else
        []
      end

    {:noreply,
     socket
     |> assign(search_form: to_form(%{"query" => query}))
     |> assign(search_results: results)}
  end

  def handle_event("add_share", %{"account_id" => account_id}, socket) do
    case Media.share_file(socket.assigns.current_user, socket.assigns.file, account_id) do
      {:ok, _share} ->
        socket =
          socket
          |> load_shares(socket.assigns.file)
          |> assign(search_form: to_form(%{"query" => ""}), search_results: [])
          |> put_flash(:info, gettext("Access granted."))

        notify_shares_changed(socket)
        {:noreply, socket}

      {:error, :cannot_share_with_owner} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot share with the owner."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to share file."))}
    end
  end

  def handle_event("remove_share_click", %{"account_id" => account_id}, socket) do
    {:noreply, assign(socket, :share_to_remove, account_id)}
  end

  def handle_event("cancel_remove_share", _params, socket) do
    {:noreply, assign(socket, :share_to_remove, nil)}
  end

  def handle_event(
        "confirm_remove_share",
        _params,
        %{assigns: %{share_to_remove: account_id}} = socket
      ) do
    case Media.revoke_file_share(socket.assigns.current_user, socket.assigns.file, account_id) do
      {:ok, :revoked} ->
        socket =
          socket
          |> load_shares(socket.assigns.file)
          |> assign(:share_to_remove, nil)
          |> put_flash(:info, gettext("Access revoked."))

        notify_shares_changed(socket)
        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:share_to_remove, nil)
         |> put_flash(:error, gettext("Failed to revoke access."))}
    end
  end

  defp notify_shares_changed(socket) do
    send(
      self(),
      {__MODULE__, {:shares_changed, socket.assigns.file.id, socket.assigns.shares != []}}
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6" id={@id}>
      <div class="p-4 bg-base-200 rounded-box border border-base-300">
        <div class="flex items-center justify-between">
          <div>
            <h4 class="font-bold text-base-content">{gettext("Public Access")}</h4>
            <p class="text-sm text-base-content/70">
              {gettext("Anyone on the platform can view and download this file.")}
            </p>
          </div>
          <.form
            for={nil}
            phx-change="toggle_public"
            phx-target={@myself}
            class="m-0 p-0 flex items-center"
          >
            <input type="hidden" name="is_public" value="false" />
            <input
              type="checkbox"
              name="is_public"
              value="true"
              class="toggle toggle-primary"
              checked={@is_public}
            />
          </.form>
        </div>
      </div>

      <div class="divider text-xs font-bold uppercase text-base-content/50">
        {gettext("Shared with")}
      </div>

      <div class="relative">
        <.form for={@search_form} phx-change="search_users" phx-target={@myself}>
          <.input
            field={@search_form[:query]}
            type="text"
            placeholder={gettext("Search by name or username to share...")}
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
            :for={account <- @search_results}
            class="flex items-center justify-between p-3 hover:bg-base-200"
          >
            <div class="flex items-center gap-2">
              <.avatar
                src={account.profile && account.profile.avatar_url}
                initials={String.slice(account.login, 0..1) |> String.upcase()}
                size="w-7"
                text_size="text-[10px]"
              />
              <span class="font-bold">{Identity.display_name(account)}</span>
            </div>
            <.button
              type="button"
              class="btn btn-xs btn-ghost text-primary"
              phx-click="add_share"
              phx-value-account_id={account.id}
              phx-target={@myself}
            >
              + {gettext("Share")}
            </.button>
          </li>
        </ul>
      </div>

      <div class="space-y-2">
        <div
          :for={share <- @shares}
          class="flex items-center justify-between p-3 bg-base-100 border border-base-200 rounded-box"
        >
          <div class="flex items-center gap-3">
            <.avatar
              initials={String.slice(share.login, 0..1) |> String.upcase()}
              size="w-8"
              text_size="text-xs"
            />
            <span class="font-bold">{share.name}</span>
          </div>

          <.icon_button
            type="button"
            size="sm"
            phx-click="remove_share_click"
            phx-value-account_id={share.account_id}
            phx-target={@myself}
            icon="hero-x-mark"
            label={gettext("Revoke Access")}
            variant="danger"
          />
        </div>

        <p :if={@shares == []} class="text-sm text-base-content/50 italic text-center py-4">
          {gettext("This file is not shared with anyone yet.")}
        </p>
      </div>

      <.modal
        id={"#{@id}-remove-share-modal"}
        show={@share_to_remove != nil}
        title={gettext("Revoke this person's access?")}
        on_cancel={JS.push("cancel_remove_share", target: @myself)}
        on_confirm={JS.push("confirm_remove_share", target: @myself)}
        confirm_label={gettext("Revoke")}
        danger={true}
      />
    </div>
    """
  end
end
