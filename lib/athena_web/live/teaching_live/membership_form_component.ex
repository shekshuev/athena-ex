defmodule AthenaWeb.TeachingLive.MembershipFormComponent do
  @moduledoc """
  A LiveComponent for adding one or more students to a cohort at once.

  Features a real-time autocomplete search for user accounts by login or
  profile name (ФИО) - matches picked from the results pile up as removable
  badges (mirroring `CohortFormComponent`'s instructor picker), and a single
  "Add" submits all of them together. The search itself is intentionally
  open, like the messenger's - see `Athena.Identity.Accounts.
  search_addable_cohort_accounts/3` - while adding each selected student to
  the cohort remains gated by the `"cohorts.update"`/`"teams.update"`
  permission in `Athena.Learning`.
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
     |> assign(:selected_accounts, [])
     |> assign(:error_msg, nil)}
  end

  @doc """
  Handles UI events: searching accounts, adding/removing them from the
  pending selection, and submitting the whole batch.
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
    selected = socket.assigns.selected_accounts

    new_selected =
      if Enum.any?(selected, &(&1.id == id)) do
        selected
      else
        selected ++ [%{id: id, login: login}]
      end

    {:noreply,
     socket
     |> assign(:selected_accounts, new_selected)
     |> assign(:search_results, [])
     |> assign(:search_query, "")
     |> assign(:error_msg, nil)}
  end

  def handle_event("remove_account", %{"id" => id}, socket) do
    new_selected = Enum.reject(socket.assigns.selected_accounts, &(&1.id == id))
    {:noreply, assign(socket, selected_accounts: new_selected)}
  end

  def handle_event("save", _, %{assigns: %{selected_accounts: []}} = socket) do
    {:noreply, assign(socket, error_msg: gettext("Please select at least one student."))}
  end

  def handle_event("save", _, socket) do
    %{
      cohort_id: cohort_id,
      selected_accounts: selected_accounts,
      current_user: current_user
    } = socket.assigns

    {added, failed} =
      Enum.reduce(selected_accounts, {0, []}, fn account, {added, failed} ->
        case Learning.add_student_to_cohort(current_user, cohort_id, account.id) do
          {:ok, membership} ->
            send(self(), {__MODULE__, {:saved, membership}})
            {added + 1, failed}

          {:error, reason} ->
            {added, [{account, reason} | failed]}
        end
      end)

    finish_save(socket, added, failed)
  end

  @doc false
  defp finish_save(socket, added, [] = _failed) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       ngettext(
         "Student successfully added to the cohort.",
         "%{count} students successfully added to the cohort.",
         added,
         count: added
       )
     )
     |> assign(:selected_accounts, [])
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:error_msg, nil)
     |> push_patch(to: socket.assigns.patch)}
  end

  # Everything failed: with just one attempted, show exactly why (mirrors
  # the single-student flow this replaced); with several, an aggregate
  # would otherwise have to guess at one shared reason.
  defp finish_save(socket, 0, [{_account, reason}]) do
    {:noreply, assign(socket, error_msg: parse_error_msg(reason))}
  end

  # Partial success/failure - keep whoever failed selected (with a hint per
  # badge below) so the instructor can see and retry/remove them, instead
  # of silently dropping who didn't make it, and don't close the sidebar.
  defp finish_save(socket, added, failed) do
    flash =
      if added == 0 do
        {:error, gettext("Failed to add the selected students.")}
      else
        {:warning,
         gettext(
           "Added %{added} student(s); %{failed} could not be added.",
           added: added,
           failed: length(failed)
         )}
      end

    {flash_type, flash_msg} = flash

    {:noreply,
     socket
     |> put_flash(flash_type, flash_msg)
     |> assign(:selected_accounts, Enum.map(failed, &elem(&1, 0)))}
  end

  @doc false
  defp parse_error_msg(%Ecto.Changeset{} = changeset) do
    if changeset.errors[:cohort_id] || changeset.errors[:account_id] do
      gettext("This student is already in the cohort.")
    else
      gettext("Failed to add student.")
    end
  end

  defp parse_error_msg(msg) when is_binary(msg), do: msg
  defp parse_error_msg(_reason), do: gettext("Failed to add student.")

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <form id="membership-form" phx-submit="save" phx-target={@myself} class="flex flex-col gap-6">
        <div class="form-control w-full relative">
          <label class="label">
            <span class="label-text font-bold">{gettext("Search Students")}</span>
          </label>

          <div :if={@selected_accounts != []} class="flex flex-wrap gap-2 mb-3">
            <%= for account <- @selected_accounts do %>
              <div class="badge badge-primary badge-lg gap-2 pl-3 pr-1 py-4">
                <span class="font-bold text-sm">{account.login}</span>
                <button
                  type="button"
                  phx-click="remove_account"
                  phx-value-id={account.id}
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
            class="absolute top-full mt-2 left-0 w-full bg-base-100 border border-base-200 rounded-lg z-50 max-h-60 overflow-y-auto"
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

          <p :if={@error_msg} class="mt-2 text-sm text-error font-bold flex items-center gap-1">
            <.icon name="hero-exclamation-circle" class="size-4" />
            {@error_msg}
          </p>
        </div>

        <div class="flex justify-end gap-3 mt-4">
          <.button type="button" variant="ghost" phx-click={JS.patch(@patch)}>
            {gettext("Cancel")}
          </.button>
          <.button type="submit" variant="primary" disabled={@selected_accounts == []}>
            <%= if length(@selected_accounts) > 1 do %>
              {gettext("Add Students (%{count})", count: length(@selected_accounts))}
            <% else %>
              {gettext("Add Student")}
            <% end %>
          </.button>
        </div>
      </form>
    </div>
    """
  end
end
