defmodule AthenaWeb.TeachingLive.MembershipFormComponent do
  @moduledoc """
  A LiveComponent for adding a student to a cohort.

  Features a real-time autocomplete search for user accounts by login or
  profile name (ФИО). The search itself is intentionally open, like the
  messenger's — see `Athena.Identity.Accounts.search_addable_cohort_accounts/3`
  — while adding the selected student to the cohort remains gated by the
  `"cohorts.update"`/`"teams.update"` permission in `Athena.Learning`.
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
      accounts = Identity.search_addable_cohort_accounts(socket.assigns.cohort_id, query, 10)
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
    %{
      cohort_id: cohort_id,
      selected_account: %{id: account_id},
      patch: patch,
      current_user: current_user
    } = socket.assigns

    case Learning.add_student_to_cohort(current_user, cohort_id, account_id) do
      {:ok, membership} ->
        send(self(), {__MODULE__, {:saved, membership}})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Student successfully added to the cohort."))
         |> assign(:selected_account, nil)
         |> assign(:search_query, "")
         |> assign(:search_results, [])
         |> assign(:error_msg, nil)
         |> push_patch(to: patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, error_msg: parse_error_msg(changeset))}

      {:error, msg} when is_binary(msg) ->
        {:noreply, assign(socket, error_msg: msg)}
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
            <span class="label-text font-bold">{gettext("Search Student")}</span>
          </label>

          <%= if @selected_account do %>
            <div class="flex items-center justify-between p-3 border border-success/30 bg-success/10 text-success-content rounded-lg">
              <div class="flex items-center gap-2">
                <.icon name="hero-user-check" class="size-5" />
                <span class="font-bold">{@selected_account.login}</span>
              </div>

              <.icon_button
                type="button"
                phx-click="clear_account"
                phx-target={@myself}
                icon="hero-x-mark"
                label={gettext("Clear")}
                variant="danger"
              />
            </div>
          <% else %>
            <div class="relative">
              <input
                type="text"
                value={@search_query}
                phx-keyup="search_accounts"
                phx-target={@myself}
                class={["input input-bordered w-full", @error_msg && "input-error"]}
                placeholder={gettext("Search by name or username...")}
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
              class="absolute top-18 left-0 w-full bg-base-100 border border-base-200 rounded-lg z-50 max-h-60 overflow-y-auto"
            >
              <%= for acc <- @search_results do %>
                <li
                  phx-click="select_account"
                  phx-target={@myself}
                  phx-value-id={acc.id}
                  phx-value-login={acc.login}
                  class="flex items-center gap-3 p-3 hover:bg-primary/10 hover:text-primary cursor-pointer border-b border-base-100 last:border-0 transition-colors"
                >
                  <.avatar
                    initials={String.slice(Identity.display_name(acc), 0..1)}
                    size="w-8"
                    text_size="text-xs"
                  />
                  <div class="min-w-0">
                    <div class="font-bold truncate">{Identity.display_name(acc)}</div>
                    <div class="text-sm opacity-60 truncate">@{acc.login}</div>
                  </div>
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
          <.button type="button" variant="ghost" phx-click={JS.patch(@patch)}>
            {gettext("Cancel")}
          </.button>
          <.button type="submit" variant="primary" disabled={is_nil(@selected_account)}>
            {gettext("Add Student")}
          </.button>
        </div>
      </form>
    </div>
    """
  end
end
