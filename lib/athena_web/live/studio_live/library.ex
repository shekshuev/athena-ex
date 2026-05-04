defmodule AthenaWeb.StudioLive.Library do
  @moduledoc """
  LiveView for managing reusable content templates (Library Blocks).
  Displays templates in a table format with contextual access controls.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.LibraryBlock
  alias Athena.Identity
  alias AthenaWeb.StudioLive.{LibraryFormComponent, LibraryShareComponent}

  on_mount {AthenaWeb.Hooks.Permission, "library.read"}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Athena.PubSub, "user_library:#{socket.assigns.current_user.id}")
      Phoenix.PubSub.subscribe(Athena.PubSub, "public_library")
    end

    {:ok,
     socket
     |> assign(block_to_delete: nil)
     |> assign(block_to_share: nil)
     |> stream(:library_blocks, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = Map.get(params, "search", "")

    flop_params =
      if search != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "title", "op" => "ilike_and", "value" => search}
        })
      else
        params
      end

    case Content.list_library_blocks(socket.assigns.current_user, flop_params) do
      {:ok, {blocks, meta}} ->
        socket =
          socket
          |> assign(meta: meta, search: search)
          |> stream(:library_blocks, blocks, reset: true)
          |> apply_action(socket.assigns.live_action, params)

        {:noreply, socket}

      {:error, _meta} ->
        {:noreply, push_patch(socket, to: ~p"/studio/library")}
    end
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: gettext("Library"), library_block: nil)
  end

  defp apply_action(socket, :new, _params) do
    if Identity.can?(socket.assigns.current_user, "library.create") do
      assign(socket, page_title: gettext("Create Template"), library_block: %LibraryBlock{})
    else
      socket
      |> put_flash(:error, gettext("You don't have permission to create templates."))
      |> push_patch(to: ~p"/studio/library")
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Content.get_library_block(socket.assigns.current_user, id) do
      {:ok, block} ->
        info = block_badges(block, socket.assigns.current_user)

        if info.role in [:owner, :writer] or
             Identity.can?(socket.assigns.current_user, "library.update", block) do
          assign(socket, page_title: gettext("Edit Template"), library_block: block)
        else
          socket
          |> put_flash(:error, gettext("You don't have permission to edit this template."))
          |> push_patch(to: ~p"/studio/library")
        end

      _ ->
        push_patch(socket, to: ~p"/studio/library")
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    params = %{"search" => search, "page" => 1, "page_size" => socket.assigns.meta.page_size}
    {:noreply, push_patch(socket, to: ~p"/studio/library?#{params}")}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    {:ok, block} = Content.get_library_block(socket.assigns.current_user, id)

    if block.owner_id == socket.assigns.current_user.id or
         Identity.can?(socket.assigns.current_user, "library.delete", block) do
      {:noreply, assign(socket, block_to_delete: block)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Only the owner can delete this template."))
       |> push_patch(to: ~p"/studio/library")}
    end
  end

  def handle_event("confirm_delete", _, %{assigns: %{block_to_delete: block}} = socket) do
    case Content.delete_library_block(socket.assigns.current_user, block) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Template deleted successfully"))
         |> stream_delete(:library_blocks, block)
         |> assign(block_to_delete: nil)}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, gettext("Failed to delete template"))}
    end
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, block_to_delete: nil)}
  end

  def handle_event("share_click", %{"id" => id}, socket) do
    case Content.get_library_block(socket.assigns.current_user, id) do
      {:ok, block} ->
        if block.owner_id == socket.assigns.current_user.id or
             Identity.can?(socket.assigns.current_user, "library.update", block) do
          {:noreply, assign(socket, block_to_share: block)}
        else
          {:noreply,
           socket |> put_flash(:error, gettext("Only the owner can share this template."))}
        end

      _ ->
        {:noreply, socket |> put_flash(:error, gettext("Cannot access this template."))}
    end
  end

  def handle_event("cancel_share", _, socket) do
    {:noreply, assign(socket, block_to_share: nil)}
  end

  @impl true
  def handle_info({LibraryFormComponent, {:saved, block}}, socket) do
    {:noreply, stream_insert(socket, :library_blocks, block)}
  end

  def handle_info({LibraryShareComponent, {:updated, block}}, socket) do
    socket =
      if socket.assigns.block_to_share && socket.assigns.block_to_share.id == block.id do
        assign(socket, block_to_share: block)
      else
        socket
      end

    {:noreply, stream_insert(socket, :library_blocks, block)}
  end

  @impl true
  def handle_info(:refresh_library, socket) do
    params = %{
      "search" => socket.assigns.search,
      "page" => socket.assigns.meta.current_page,
      "page_size" => socket.assigns.meta.page_size
    }

    flop_params =
      if params["search"] != "" do
        Map.put(params, "filters", %{
          "0" => %{"field" => "title", "op" => "ilike_and", "value" => params["search"]}
        })
      else
        params
      end

    case Content.list_library_blocks(socket.assigns.current_user, flop_params) do
      {:ok, {blocks, meta}} ->
        {:noreply,
         socket
         |> assign(meta: meta)
         |> stream(:library_blocks, blocks, reset: true)}

      {:error, _meta} ->
        {:noreply, socket}
    end
  end

  defp block_badges(block, user) do
    shares = Content.list_block_shares(block)

    role =
      cond do
        block.owner_id == user.id -> :owner
        share = Enum.find(shares, &(&1.account_id == user.id)) -> share.role
        true -> :none
      end

    %{
      role: role,
      is_public: block.is_public,
      shares_count: length(shares)
    }
  end

  defp access_badges(assigns) do
    ~H"""
    <div class="flex gap-1 items-center">
      <span
        :if={@info.role != :none}
        class={[
          "badge badge-xs font-bold uppercase shrink-0",
          @info.role == :owner && "badge-primary badge-soft",
          @info.role == :writer && "badge-secondary badge-soft",
          @info.role == :reader && "badge-accent badge-soft"
        ]}
      >
        {Atom.to_string(@info.role)}
      </span>

      <span
        :if={@info.is_public}
        class="badge badge-xs badge-neutral font-bold uppercase shrink-0"
      >
        <.icon name="hero-eye" class="size-3 mr-1" />
        {gettext("Public")}
      </span>

      <span
        :if={!@info.is_public and @info.shares_count > 0 and @info.role == :owner}
        class="badge badge-xs badge-info badge-soft font-bold shrink-0"
      >
        <.icon name="hero-users" class="size-3 mr-1" />
        {@info.shares_count}
      </span>
    </div>
    """
  end

  defp type_badge(assigns) do
    ~H"""
    <span class="badge badge-sm font-bold shadow-sm border border-base-200 bg-base-100 text-base-content/70 uppercase tracking-widest text-[10px]">
      {Atom.to_string(@type) |> String.replace("_", " ")}
    </span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Library")}</h1>
          <p class="text-base-content/60">
            {gettext("Manage reusable content templates and quiz questions.")}
          </p>
        </div>
        <.button
          :if={Identity.can?(@current_user, "library.create")}
          patch={~p"/studio/library/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-5" />
          {gettext("Create Template")}
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
              placeholder={gettext("Search templates...")}
              class="input input-bordered w-full pl-10"
              phx-debounce="500"
            />
          </div>
        </.form>
      </div>

      <.table id="library-blocks" rows={@streams.library_blocks}>
        <:col :let={{_id, block}} label={gettext("Title")}>
          <div class="flex flex-col gap-1 items-start">
            <span class="font-bold">{block.title}</span>
            <.access_badges info={block_badges(block, @current_user)} />
          </div>
        </:col>
        <:col :let={{_id, block}} label={gettext("Type")}>
          <.type_badge type={block.type} />
        </:col>
        <:col :let={{_id, block}} label={gettext("Created At")}>
          <span class="text-sm opacity-60">{Calendar.strftime(block.inserted_at, "%d.%m.%Y")}</span>
        </:col>
        <:action :let={{_id, block}}>
          <% info = block_badges(block, @current_user) %>
          <% can_edit =
            info.role in [:owner, :writer] or Identity.can?(@current_user, "library.update", block) %>
          <% can_view = can_edit or info.role == :reader or info.is_public %>

          <div class="flex justify-end gap-2">
            <.button
              :if={can_view}
              navigate={~p"/studio/library/#{block.id}/editor"}
              class="btn btn-primary btn-xs btn-square btn-soft"
              title={if can_edit, do: gettext("Open Editor"), else: gettext("View Template")}
            >
              <.icon
                name={if can_edit, do: "hero-wrench-screwdriver", else: "hero-eye"}
                class="size-4"
              />
            </.button>

            <.button
              :if={can_edit}
              patch={~p"/studio/library/#{block.id}/edit"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Edit Metadata")}
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </.button>

            <.button
              :if={info.role == :owner or Identity.can?(@current_user, "library.update", block)}
              type="button"
              phx-click="share_click"
              phx-value-id={block.id}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Share Access")}
            >
              <.icon name="hero-share" class="size-4" />
            </.button>

            <.button
              :if={info.role == :owner or Identity.can?(@current_user, "library.delete", block)}
              type="button"
              phx-click="delete_click"
              phx-value-id={block.id}
              class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10"
              title={gettext("Delete")}
            >
              <.icon name="hero-trash" class="size-4" />
            </.button>
          </div>
        </:action>
      </.table>

      <div class="flex justify-end mt-8">
        <.pagination
          meta={@meta}
          path_fn={fn p -> ~p"/studio/library?#{%{"page" => p, "search" => @search}}" end}
        />
      </div>

      <.slide_over
        id="library-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/studio/library")}
      >
        <.live_component
          :if={@library_block}
          module={LibraryFormComponent}
          id={@library_block.id || :new}
          action={@live_action}
          library_block={@library_block}
          current_user={@current_user}
          patch={~p"/studio/library"}
        />
      </.slide_over>

      <.modal
        id="delete-library-modal"
        show={@block_to_delete != nil}
        title={gettext("Delete Template")}
        description={
          gettext(
            "Are you sure you want to permanently delete this template? This action cannot be undone."
          )
        }
        confirm_label={gettext("Delete")}
        danger={true}
        on_cancel={JS.push("cancel_delete")}
        on_confirm={JS.push("confirm_delete")}
      />

      <.modal
        id="share-library-modal"
        show={@block_to_share != nil}
        title={
          gettext("Share Template: %{title}",
            title: if(@block_to_share, do: @block_to_share.title, else: "")
          )
        }
        on_cancel={JS.push("cancel_share")}
      >
        <.live_component
          :if={@block_to_share}
          module={LibraryShareComponent}
          id={"share-#{@block_to_share.id}"}
          library_block={@block_to_share}
          current_user={@current_user}
        />
      </.modal>
    </div>
    """
  end
end
