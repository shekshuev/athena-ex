defmodule AthenaWeb.AdminLive.Gamification do
  @moduledoc """
  Admin badge catalog. Badges are authored as a small rule-DSL (a JSON
  condition tree over measurable facts — see `Athena.Gamification.Badge`),
  not free-form logic: the admin picks facts/operators/thresholds already
  known to the system, so a badge can't reference something nothing
  tracks. Includes a "test on a student" preview so an admin can sanity
  check a rule against a real account before flipping it active.
  """
  use AthenaWeb, :live_view

  alias Athena.{Identity, Gamification}
  alias Athena.Gamification.Badge

  on_mount {AthenaWeb.Hooks.Permission, "gamification.read"}

  @impl true
  def mount(_params, _session, socket) do
    badges = Gamification.list_badges()

    {:ok,
     socket
     |> assign(:test_result, nil)
     |> assign(:known_facts, Enum.join(Gamification.known_facts(), ", "))
     |> assign(:badges_count, length(badges))
     |> assign(:badge_to_delete, nil)
     |> stream(:badges, badges)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Badges"), badge: nil, form: nil, rule_text: nil)
  end

  defp apply_action(socket, :new, _params) do
    if can_create?(socket) do
      badge = %Badge{rule: %{}}

      socket
      |> assign(page_title: gettext("New Badge"), badge: badge)
      |> assign(:rule_text, "{}")
      |> assign(:test_result, nil)
      |> assign(:form, to_form(Badge.changeset(badge, %{})))
    else
      deny(socket)
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    if can_update?(socket) do
      case Gamification.get_badge(id) do
        {:ok, badge} ->
          socket
          |> assign(page_title: gettext("Edit Badge"), badge: badge)
          |> assign(:rule_text, Jason.encode!(badge.rule, pretty: true))
          |> assign(:test_result, nil)
          |> assign(:form, to_form(Badge.changeset(badge, %{})))

        _ ->
          push_patch(socket, to: ~p"/admin/gamification")
      end
    else
      deny(socket)
    end
  end

  defp can_create?(socket), do: Identity.can?(socket.assigns.current_user, "gamification.create")
  defp can_update?(socket), do: Identity.can?(socket.assigns.current_user, "gamification.update")
  defp can_delete?(socket), do: Identity.can?(socket.assigns.current_user, "gamification.delete")

  defp deny(socket) do
    socket
    |> put_flash(:error, gettext("You don't have permission to manage badges."))
    |> push_patch(to: ~p"/admin/gamification")
  end

  @impl true
  def handle_event("validate", %{"badge" => params} = full_params, socket) do
    params = Map.put(params, "rule", decode_rule(full_params["rule_text"]))

    changeset =
      socket.assigns.badge
      |> Badge.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:rule_text, full_params["rule_text"])
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("save", %{"badge" => params} = full_params, socket) do
    if save_authorized?(socket) do
      case Jason.decode(full_params["rule_text"] || "") do
        {:ok, rule} ->
          save_badge(socket, socket.assigns.live_action, Map.put(params, "rule", rule))

        {:error, _} ->
          changeset =
            socket.assigns.badge
            |> Badge.changeset(params)
            |> Ecto.Changeset.add_error(:rule, "is not valid JSON")
            |> Map.put(:action, :insert)

          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, deny(socket)}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with true <- can_update?(socket),
         {:ok, badge} <- Gamification.get_badge(id),
         {:ok, updated} <-
           Gamification.update_badge(user, badge, %{"is_active" => !badge.is_active}) do
      {:noreply, stream_insert(socket, :badges, updated)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    with true <- can_delete?(socket),
         {:ok, badge} <- Gamification.get_badge(id) do
      {:noreply, assign(socket, :badge_to_delete, badge)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :badge_to_delete, nil)}
  end

  def handle_event("confirm_delete", _params, %{assigns: %{badge_to_delete: badge}} = socket) do
    user = socket.assigns.current_user

    case Gamification.delete_badge(user, badge) do
      {:ok, _} ->
        {:noreply,
         socket
         |> stream_delete(:badges, badge)
         |> assign(:badges_count, socket.assigns.badges_count - 1)
         |> assign(:badge_to_delete, nil)}

      _ ->
        {:noreply, assign(socket, :badge_to_delete, nil)}
    end
  end

  def handle_event("test_rule", %{"login" => login}, socket) do
    result =
      with {:ok, account} <- Identity.get_account_by_login(login),
           {:ok, rule} <- Jason.decode(socket.assigns.rule_text || "") do
        {login, Gamification.test_rule(rule, account.id)}
      else
        {:error, :not_found} -> {login, :not_found}
        _ -> {login, :invalid_rule}
      end

    {:noreply, assign(socket, :test_result, result)}
  end

  defp save_authorized?(%{assigns: %{live_action: :new}} = socket), do: can_create?(socket)
  defp save_authorized?(%{assigns: %{live_action: :edit}} = socket), do: can_update?(socket)
  defp save_authorized?(_socket), do: false

  defp decode_rule(json) do
    case Jason.decode(json || "") do
      {:ok, rule} -> rule
      {:error, _} -> %{}
    end
  end

  defp save_badge(socket, :new, params) do
    case Gamification.create_badge(socket.assigns.current_user, params) do
      {:ok, badge} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Badge created."))
         |> stream_insert(:badges, badge, at: 0)
         |> assign(:badges_count, socket.assigns.badges_count + 1)
         |> push_patch(to: ~p"/admin/gamification")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_badge(socket, :edit, params) do
    case Gamification.update_badge(socket.assigns.current_user, socket.assigns.badge, params) do
      {:ok, badge} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Badge updated."))
         |> stream_insert(:badges, badge)
         |> push_patch(to: ~p"/admin/gamification")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between flex-wrap gap-4">
        <div>
          <h1 class="text-3xl font-display font-black uppercase tracking-tight">
            {gettext("Badges")}
          </h1>
          <p class="text-base-content/60 text-sm mt-1">
            {gettext("Facts available to rules: %{facts}", facts: @known_facts)}
          </p>
        </div>
        <.button variant="primary" patch={~p"/admin/gamification/new"}>
          <.icon name="hero-plus" class="size-4" />
          {gettext("New Badge")}
        </.button>
      </div>

      <div class="overflow-x-auto border border-base-300 rounded-sm">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Badge")}</th>
              <th>{gettext("Key")}</th>
              <th>{gettext("Scope")}</th>
              <th>{gettext("Active")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="badges" phx-update="stream">
            <tr :for={{dom_id, badge} <- @streams.badges} id={dom_id}>
              <td>
                <div class="flex items-center gap-2">
                  <.icon name={badge.icon} class="size-5 text-primary" />
                  <div>
                    <div class="font-bold">{badge.title}</div>
                    <div class="text-xs text-base-content/50">{badge.description}</div>
                  </div>
                </div>
              </td>
              <td><code class="text-xs">{badge.key}</code></td>
              <td>{badge.scope}</td>
              <td>
                <button
                  type="button"
                  phx-click="toggle_active"
                  phx-value-id={badge.id}
                  class={[
                    "badge",
                    badge.is_active && "badge-success",
                    !badge.is_active && "badge-ghost"
                  ]}
                >
                  {if badge.is_active, do: gettext("Active"), else: gettext("Inactive")}
                </button>
              </td>
              <td class="text-right">
                <.icon_button
                  patch={~p"/admin/gamification/#{badge.id}/edit"}
                  icon="hero-pencil-square"
                  label={gettext("Edit")}
                />
                <.icon_button
                  type="button"
                  phx-click="delete_click"
                  phx-value-id={badge.id}
                  icon="hero-trash"
                  label={gettext("Delete")}
                  variant="danger"
                />
              </td>
            </tr>
          </tbody>
        </table>

        <.empty_state
          :if={@badges_count == 0}
          icon="hero-sparkles"
          title={gettext("No badges yet")}
          description={gettext("Create one to get started.")}
        />
      </div>

      <.modal
        id="delete-badge-modal"
        show={@badge_to_delete != nil}
        title={gettext("Delete this badge?")}
        description={gettext("Existing awards are removed too.")}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
        confirm_label={gettext("Delete")}
        danger={true}
      />

      <.modal
        :if={@live_action in [:new, :edit]}
        id="badge-modal"
        show={true}
        title={@page_title}
        on_cancel={JS.patch(~p"/admin/gamification")}
      >
        <.form for={@form} id="badge-form" phx-change="validate" phx-submit="save" class="space-y-4">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input field={@form[:key]} type="text" label={gettext("Key (slug)")} required />
            <.input field={@form[:title]} type="text" label={gettext("Title")} required />
          </div>
          <.input field={@form[:description]} type="text" label={gettext("Description")} />
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <.input field={@form[:icon]} type="text" label={gettext("Icon (heroicon name)")} />
            <.input
              field={@form[:scope]}
              type="select"
              label={gettext("Scope")}
              options={[
                {gettext("Global"), :global},
                {gettext("Course"), :course},
                {gettext("Cohort"), :cohort}
              ]}
            />
            <.input field={@form[:scope_id]} type="text" label={gettext("Scope ID")} />
          </div>
          <.input field={@form[:is_active]} type="checkbox" label={gettext("Active")} />

          <div>
            <label class="label">
              <span class="label-text font-bold">{gettext("Rule (JSON)")}</span>
            </label>
            <textarea
              name="rule_text"
              rows="8"
              class="textarea textarea-bordered w-full font-mono text-xs"
              phx-debounce="300"
            ><%= @rule_text %></textarea>
            <div
              :for={{msg, _opts} <- @form[:rule].errors || []}
              class="text-error text-xs font-bold mt-1"
            >
              {gettext("Rule")}: {msg}
            </div>
          </div>

          <div class="flex justify-end gap-3">
            <.button variant="ghost" patch={~p"/admin/gamification"}>{gettext("Cancel")}</.button>
            <.button type="submit" variant="primary" phx-disable-with={gettext("Saving...")}>
              {gettext("Save")}
            </.button>
          </div>
        </.form>

        <div class="divider text-xs font-bold uppercase text-base-content/50 mt-6">
          {gettext("Test on a student")}
        </div>
        <form phx-submit="test_rule" class="flex items-end gap-3">
          <div class="flex-1">
            <label class="label"><span class="label-text">{gettext("Login")}</span></label>
            <input name="login" type="text" class="input input-bordered w-full" required />
          </div>
          <.button type="submit">{gettext("Test")}</.button>
        </form>
        <div :if={@test_result} class="mt-2 text-sm font-bold">
          <% {login, result} = @test_result %>
          <%= case result do %>
            <% :not_found -> %>
              <span class="text-error">
                {gettext("No account with login \"%{login}\"", login: login)}
              </span>
            <% :invalid_rule -> %>
              <span class="text-error">{gettext("Rule is not valid JSON")}</span>
            <% true -> %>
              <span class="text-success">
                {gettext("%{login} would earn this badge", login: login)}
              </span>
            <% false -> %>
              <span class="text-base-content/60">
                {gettext("%{login} does not qualify yet", login: login)}
              </span>
          <% end %>
        </div>
      </.modal>
    </div>
    """
  end
end
