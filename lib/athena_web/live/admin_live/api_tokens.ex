defmodule AthenaWeb.AdminLive.ApiTokens do
  @moduledoc """
  LiveView for managing MCP personal access tokens.

  Displays a paginated table over every token visible to the current
  account: everyone under the `"own_only"` policy on `"mcp.tokens.read"`
  sees only their own tokens, while a role granted that permission without
  the policy (e.g. admin) sees every token in the system, along with whose
  account it belongs to. Create/read/delete only - tokens are never updated
  in place, only issued or revoked.
  """
  use AthenaWeb, :live_view

  alias Athena.Identity

  on_mount {AthenaWeb.Hooks.Permission, "mcp.tokens.read"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(creating_token?: false, raw_token: nil, token_to_delete: nil)
     |> assign(:label_form, to_form(%{"label" => ""}, as: "token"))
     |> stream(:tokens, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")

    flop_params =
      if search != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "label", "op" => "ilike_and", "value" => search}
        })
      else
        params
      end

    case Identity.list_tokens(socket.assigns.current_user, flop_params) do
      {:ok, {tokens, meta}} ->
        owners =
          tokens
          |> Enum.map(& &1.owner_id)
          |> Enum.uniq()
          |> Identity.get_accounts_map()

        {:noreply,
         socket
         |> assign(meta: meta, search: search, owners: owners)
         |> stream(:tokens, tokens, reset: true)}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/admin/tokens")}
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = build_query_params(socket.assigns, %{"search" => search, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/admin/tokens?#{params}")}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})
    {:noreply, push_patch(socket, to: ~p"/admin/tokens?#{params}")}
  end

  def handle_event("new_token_click", _params, socket) do
    if Identity.can?(socket.assigns.current_user, "mcp.tokens.create") do
      {:noreply, assign(socket, creating_token?: true)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to create tokens."))}
    end
  end

  def handle_event("cancel_new_token", _params, socket) do
    {:noreply, assign(socket, creating_token?: false, raw_token: nil)}
  end

  def handle_event("create_token", %{"token" => %{"label" => label}}, socket) do
    account = socket.assigns.current_user

    case Identity.generate_token(account, %{"label" => label}) do
      {:ok, raw_token, token} ->
        owners = Map.put_new(socket.assigns.owners, token.owner_id, account)

        {:noreply,
         socket
         |> assign(raw_token: raw_token, owners: owners)
         |> assign(:label_form, to_form(%{"label" => ""}, as: "token"))
         |> stream_insert(:tokens, token, at: 0)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You don't have permission to create tokens."))
         |> assign(creating_token?: false)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create the token."))}
    end
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    if Identity.can?(socket.assigns.current_user, "mcp.tokens.delete") do
      case Identity.get_token(id) do
        {:ok, token} -> {:noreply, assign(socket, token_to_delete: token)}
        {:error, :not_found} -> {:noreply, socket}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to delete tokens."))}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, token_to_delete: nil)}
  end

  def handle_event("confirm_delete", _params, %{assigns: %{token_to_delete: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event(
        "confirm_delete",
        _params,
        %{assigns: %{token_to_delete: token, current_user: user}} = socket
      ) do
    case Identity.revoke_token(user, token) do
      {:ok, revoked} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Token revoked successfully"))
         |> stream_delete(:tokens, revoked)
         |> assign(token_to_delete: nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to revoke token"))
         |> assign(token_to_delete: nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_container size="wide" class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("MCP Tokens")}</h1>
          <p class="text-base-content/60">
            {gettext("Personal access tokens that let AI agents create and manage courses via MCP.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "mcp.tokens.create")}
          type="button"
          variant="primary"
          phx-click="new_token_click"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("New Token")}
        </.button>
      </div>

      <div class="flex gap-4">
        <.form for={nil} phx-change="search" phx-submit="search" class="w-full max-w-sm">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-3 top-3.5 size-5 text-base-content/50 z-10"
            />
            <.input
              type="text"
              name="search"
              value={@search}
              placeholder={gettext("Search by label...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <% path_fn = fn overrides -> ~p"/admin/tokens?#{build_query_params(assigns, overrides)}" end %>

      <.table id="admin-tokens" rows={@streams.tokens} meta={@meta} path_fn={path_fn}>
        <:col :let={{_id, token}} label={gettext("Label")} sort="label">
          <span class="font-bold">{token.label}</span>
        </:col>
        <:col :let={{_id, token}} label={gettext("Owner")}>
          {owner_name(@owners, token.owner_id)}
        </:col>
        <:col :let={{_id, token}} label={gettext("Token")}>
          <span class="font-mono text-xs opacity-60">athn_{token.token_prefix}...</span>
        </:col>
        <:col :let={{_id, token}} label={gettext("Status")}>
          <.badge tone={if expired?(token), do: "warning", else: "success"}>
            {if expired?(token), do: gettext("Expired"), else: gettext("Active")}
          </.badge>
        </:col>
        <:col :let={{_id, token}} label={gettext("Last Used")} sort="last_used_at">
          <span class="text-sm opacity-60">
            {if token.last_used_at,
              do: Calendar.strftime(token.last_used_at, "%d.%m.%Y %H:%M"),
              else: gettext("Never")}
          </span>
        </:col>
        <:col :let={{_id, token}} label={gettext("Expires")} sort="expires_at">
          <span class="text-sm opacity-60">
            {if token.expires_at,
              do: Calendar.strftime(token.expires_at, "%d.%m.%Y"),
              else: gettext("Never")}
          </span>
        </:col>
        <:col :let={{_id, token}} label={gettext("Created At")} sort="inserted_at">
          <span class="text-sm opacity-60">{Calendar.strftime(token.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, token}}>
          <div class="flex justify-end gap-2">
            <.icon_button
              :if={Identity.can?(@current_user, "mcp.tokens.delete")}
              type="button"
              phx-click="delete_click"
              phx-value-id={token.id}
              icon="hero-trash"
              label={gettext("Revoke")}
              variant="danger"
            />
          </div>
        </:action>
      </.table>

      <.empty_state
        :if={@meta.total_count == 0}
        icon="hero-key"
        title={gettext("No tokens yet")}
        description={gettext("Create one to let an MCP agent manage courses.")}
      />

      <div class="flex justify-end">
        <.pagination meta={@meta} path_fn={path_fn} />
      </div>

      <.modal
        id="new-token-modal"
        show={@creating_token?}
        title={gettext("New MCP Token")}
        on_cancel={JS.push("cancel_new_token")}
      >
        <div :if={@raw_token} class="space-y-4">
          <div class="alert alert-warning">
            {gettext("Copy this token now - it won't be shown again.")}
          </div>
          <input
            type="text"
            readonly
            value={@raw_token}
            onclick="this.select()"
            class="input input-bordered w-full font-mono text-sm"
          />
          <div class="flex justify-end">
            <.button type="button" variant="primary" phx-click="cancel_new_token">
              {gettext("Done")}
            </.button>
          </div>
        </div>

        <.form
          :if={!@raw_token}
          for={@label_form}
          id="token-form"
          phx-submit="create_token"
          class="space-y-4"
        >
          <.input
            field={@label_form[:label]}
            type="text"
            label={gettext("Label")}
            placeholder={gettext("e.g. \"Course-building agent\"")}
            required
          />
          <div class="flex justify-end gap-3">
            <.button type="button" phx-click="cancel_new_token">{gettext("Cancel")}</.button>
            <.button type="submit" variant="primary" phx-disable-with={gettext("Creating...")}>
              {gettext("Generate token")}
            </.button>
          </div>
        </.form>
      </.modal>

      <.modal
        id="delete-token-modal"
        show={@token_to_delete != nil}
        title={gettext("Revoke Token")}
        description={
          gettext("Are you sure? Any agent using this token will lose access immediately.")
        }
        confirm_label={gettext("Revoke")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />
    </.page_container>
    """
  end

  defp owner_name(owners, owner_id) do
    case Map.get(owners, owner_id) do
      nil -> "—"
      account -> Identity.display_name(account)
    end
  end

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  @doc false
  defp build_query_params(assigns, overrides) do
    meta = assigns.meta

    order_by =
      meta.flop.order_by
      |> List.wrap()
      |> Enum.map(&to_string/1)

    order_directions =
      meta.flop.order_directions
      |> List.wrap()
      |> Enum.map(&to_string/1)

    %{
      "search" => assigns.search,
      "page" => meta.current_page,
      "page_size" => meta.page_size,
      "order_by" => order_by,
      "order_directions" => order_directions
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end
end
