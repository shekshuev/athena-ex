defmodule AthenaWeb.TeachingLive.MembershipFormComponent do
  @moduledoc """
  A LiveComponent for adding a student to a cohort.

  Features a real-time autocomplete search for user accounts by login.
  Delegates database operations to the `Athena.Learning` context 
  and account searching to the `Athena.Identity` context.
  """
  use AthenaWeb, :live_component

  alias Athena.Identity
  alias Athena.Learning

  @doc """
  Initializes the component state with empty search results and selection.
  """
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:selected_account, nil)
     |> assign(:error_msg, nil)}
  end

  @doc """
  Handles UI events: searching accounts, selecting/clearing the account,
  and submitting the membership form.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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
    {:noreply,
     socket
     |> assign(:selected_account, %{id: id, login: login})
     |> assign(:search_results, [])
     |> assign(:search_query, "")
     |> assign(:error_msg, nil)}
  end

  def handle_event("clear_account", _, socket) do
    {:noreply, assign(socket, selected_account: nil, error_msg: nil)}
  end

  def handle_event("save", _, %{assigns: %{selected_account: nil}} = socket) do
    {:noreply, assign(socket, error_msg: gettext("Please select a student."))}
  end

  def handle_event("save", _, socket) do
    %{cohort_id: cohort_id, selected_account: %{id: account_id}, patch: patch} = socket.assigns

    case Learning.add_student_to_cohort(cohort_id, account_id) do
      {:ok, membership} ->
        send(self(), {__MODULE__, {:saved, membership}})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Student successfully added to the cohort."))
         |> push_patch(to: patch)}

      {:error, changeset} ->
        {:noreply, assign(socket, error_msg: parse_error_msg(changeset))}
    end
  end

  @doc false
  defp parse_error_msg(changeset) do
    if changeset.errors[:cohort_id] || changeset.errors[:account_id] do
      gettext("This student is already in the cohort.")
    else
      gettext("Failed to add student.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <form id="membership-form" phx-submit="save" phx-target={@myself} class="flex flex-col gap-6">
        <div class="form-control w-full relative">
          <label class="label">
            <span class="label-text font-bold">{gettext("Search User by Login")}</span>
          </label>

          <%= if @selected_account do %>
            <div class="flex items-center justify-between p-3 border border-success/30 bg-success/10 text-success-content rounded-lg">
              <div class="flex items-center gap-2">
                <.icon name="hero-user-check" class="size-5" />
                <span class="font-bold">{@selected_account.login}</span>
              </div>

              <.button
                type="button"
                phx-click="clear_account"
                phx-target={@myself}
                class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/20"
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
                class={["input input-bordered w-full", @error_msg && "input-error"]}
                placeholder={gettext("Type at least 2 characters...")}
                autocomplete="off"
                phx-debounce="300"
                autofocus
              />
              <.icon
                name="hero-magnifying-glass"
                class="absolute right-3 top-3.5 size-5 text-base-content/40"
              />
            </div>

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

          <p :if={@error_msg} class="mt-2 text-sm text-error font-bold flex items-center gap-1">
            <.icon name="hero-exclamation-circle" class="size-4" />
            {@error_msg}
          </p>
        </div>

        <div class="flex justify-end gap-3 mt-4">
          <.button
            type="button"
            class="btn btn-ghost"
            phx-click={JS.patch(@patch)}
          >
            {gettext("Cancel")}
          </.button>
          <.button type="submit" class="btn btn-primary" disabled={is_nil(@selected_account)}>
            {gettext("Add Student")}
          </.button>
        </div>
      </form>
    </div>
    """
  end
end
