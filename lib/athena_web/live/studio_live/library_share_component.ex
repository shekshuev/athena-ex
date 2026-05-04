defmodule AthenaWeb.StudioLive.LibraryShareComponent do
  @moduledoc """
  LiveComponent for managing library block visibility and sharing access.
  """
  use AthenaWeb, :live_component

  alias Athena.Content
  alias Athena.Identity

  @impl true
  def update(%{library_block: library_block} = assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(search_form: to_form(%{"query" => ""}))
      |> assign(search_results: [])
      |> load_shares(library_block)

    {:ok, socket}
  end

  defp load_shares(socket, library_block) do
    shares = Content.list_block_shares(library_block)
    account_ids = Enum.map(shares, & &1.account_id)
    accounts_map = Identity.get_accounts_map(account_ids)

    enriched_shares =
      shares
      |> Enum.map(fn share ->
        account = Map.get(accounts_map, share.account_id)

        %{
          account_id: share.account_id,
          role: share.role,
          login: if(account, do: account.login, else: "Unknown")
        }
      end)
      |> Enum.sort_by(& &1.login)

    socket
    |> assign(shares: enriched_shares, is_public: library_block.is_public)
  end

  @impl true
  def handle_event("toggle_public", %{"is_public" => is_public_str}, socket) do
    is_public = is_public_str == "true"

    case Content.toggle_block_public(
           socket.assigns.current_user,
           socket.assigns.library_block,
           is_public
         ) do
      {:ok, updated_block} ->
        send(self(), {__MODULE__, {:updated, updated_block}})
        {:noreply, assign(socket, is_public: updated_block.is_public)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update visibility."))}
    end
  end

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

  def handle_event("add_share", %{"account_id" => account_id, "role" => role}, socket) do
    role_atom = String.to_existing_atom(role)

    case Content.share_block(
           socket.assigns.current_user,
           socket.assigns.library_block,
           account_id,
           role_atom
         ) do
      {:ok, _share} ->
        socket =
          socket
          |> load_shares(socket.assigns.library_block)
          |> assign(search_form: to_form(%{"query" => ""}), search_results: [])
          |> put_flash(:info, gettext("Access granted."))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to share template."))}
    end
  end

  def handle_event("remove_share", %{"account_id" => account_id}, socket) do
    case Content.revoke_block_share(
           socket.assigns.current_user,
           socket.assigns.library_block,
           account_id
         ) do
      {:ok, :revoked} ->
        socket =
          socket
          |> load_shares(socket.assigns.library_block)
          |> put_flash(:info, gettext("Access revoked."))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to revoke access."))}
    end
  end

  def handle_event("change_role", %{"account_id" => account_id, "role" => new_role}, socket) do
    role_atom = String.to_existing_atom(new_role)

    case Content.share_block(
           socket.assigns.current_user,
           socket.assigns.library_block,
           account_id,
           role_atom
         ) do
      {:ok, _share} ->
        socket = load_shares(socket, socket.assigns.library_block)
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to change role."))}
    end
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
              {gettext("Anyone on the platform can view and insert this template.")}
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
        {gettext("Collaborators")}
      </div>

      <div class="relative">
        <.form for={@search_form} phx-change="search_users" phx-target={@myself}>
          <.input
            field={@search_form[:query]}
            type="text"
            placeholder={gettext("Search user by login to share...")}
            autocomplete="off"
            phx-debounce="300"
            class="input input-bordered w-full"
          />
        </.form>

        <ul
          :if={@search_results != []}
          class="absolute z-50 w-full mt-1 bg-base-100 border border-base-300 rounded-box shadow-xl max-h-60 overflow-y-auto"
        >
          <li
            :for={user <- @search_results}
            class="flex items-center justify-between p-3 hover:bg-base-200"
          >
            <span class="font-bold">{user.login}</span>
            <div class="flex gap-2">
              <.button
                type="button"
                class="btn btn-xs btn-ghost text-primary"
                phx-click="add_share"
                phx-value-account_id={user.id}
                phx-value-role="reader"
                phx-target={@myself}
              >
                + Reader
              </.button>
              <.button
                type="button"
                class="btn btn-xs btn-ghost text-secondary"
                phx-click="add_share"
                phx-value-account_id={user.id}
                phx-value-role="writer"
                phx-target={@myself}
              >
                + Writer
              </.button>
            </div>
          </li>
        </ul>
      </div>

      <div class="space-y-2 max-h-[50vh] overflow-y-auto pr-2 scrollbar-thin">
        <div
          :for={share <- @shares}
          class="flex items-center justify-between p-3 bg-base-100 border border-base-200 rounded-box"
        >
          <div class="flex items-center gap-3 min-w-0">
            <div class="avatar placeholder shrink-0">
              <div class="bg-neutral text-neutral-content rounded-full w-8">
                <span class="text-xs uppercase">{String.slice(share.login, 0..1)}</span>
              </div>
            </div>
            <span class="font-bold truncate">{share.login}</span>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <.form for={nil} phx-change="change_role" phx-target={@myself} class="m-0 p-0">
              <input type="hidden" name="account_id" value={share.account_id} />
              <select name="role" class="select select-bordered select-sm">
                <option value="reader" selected={share.role == :reader}>Reader</option>
                <option value="writer" selected={share.role == :writer}>Writer</option>
              </select>
            </.form>

            <.button
              type="button"
              class="btn btn-ghost btn-sm btn-square text-error hover:bg-error/10"
              phx-click="remove_share"
              phx-value-account_id={share.account_id}
              phx-target={@myself}
              title={gettext("Revoke Access")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </.button>
          </div>
        </div>

        <p :if={@shares == []} class="text-sm text-base-content/50 italic text-center py-4">
          {gettext("This template is currently private.")}
        </p>
      </div>
    </div>
    """
  end
end
