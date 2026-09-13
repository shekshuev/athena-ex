defmodule AthenaWeb.MessengerLive.NewDmComponent do
  @moduledoc """
  Search for any user on the platform (by login or profile name) and start
  a direct conversation with them. The messenger is intentionally open —
  see `Athena.Identity.Accounts.search_messageable_accounts/3` for the
  deliberate ACL exception this relies on.
  """
  use AthenaWeb, :live_component

  alias Athena.Identity
  alias Athena.Messaging

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:search_form, fn -> to_form(%{"query" => ""}) end)
      |> assign_new(:search_results, fn -> [] end)

    {:ok, socket}
  end

  @impl true
  def handle_event("search_users", %{"query" => query}, socket) do
    results =
      if String.length(String.trim(query)) >= 2 do
        Identity.search_messageable_accounts(socket.assigns.current_user, String.trim(query), 10)
      else
        []
      end

    {:noreply,
     socket
     |> assign(search_form: to_form(%{"query" => query}))
     |> assign(search_results: results)}
  end

  def handle_event("start_conversation", %{"account_id" => account_id}, socket) do
    case Messaging.find_or_create_direct_conversation(socket.assigns.current_user, account_id) do
      {:ok, conversation} ->
        send(self(), {__MODULE__, {:started, conversation}})
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not start this conversation."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full" id={@id}>
      <div class="h-16 flex items-center gap-3 px-4 border-b border-base-300 shrink-0">
        <.button navigate={~p"/messenger"} variant="ghost" size="sm" class="btn-square">
          <.icon name="hero-arrow-left" class="size-5" />
        </.button>
        <h2 class="text-lg font-display font-bold">{gettext("New Message")}</h2>
      </div>

      <div class="p-4 max-w-md w-full mx-auto">
        <.form for={@search_form} phx-change="search_users" phx-target={@myself}>
          <.input
            field={@search_form[:query]}
            type="text"
            placeholder={gettext("Search by name or username...")}
            autocomplete="off"
            phx-debounce="300"
            class="input input-bordered w-full"
          />
        </.form>

        <ul class="mt-2 divide-y divide-base-200">
          <li :for={account <- @search_results}>
            <button
              type="button"
              phx-click="start_conversation"
              phx-value-account_id={account.id}
              phx-target={@myself}
              class="w-full flex items-center gap-3 p-3 hover:bg-base-200 rounded-box text-left"
            >
              <div class="avatar placeholder shrink-0">
                <div class="bg-neutral text-neutral-content rounded-full w-9">
                  <span class="text-xs uppercase">
                    {String.slice(Identity.display_name(account), 0..1)}
                  </span>
                </div>
              </div>
              <div class="min-w-0">
                <div class="font-bold truncate">{Identity.display_name(account)}</div>
                <div class="text-sm text-base-content/60 truncate">@{account.login}</div>
              </div>
            </button>
          </li>
        </ul>

        <p
          :if={
            @search_results == [] && String.length(String.trim(@search_form[:query].value || "")) >= 2
          }
          class="text-sm text-base-content/50 italic text-center py-6"
        >
          {gettext("No users found.")}
        </p>
      </div>
    </div>
    """
  end
end
