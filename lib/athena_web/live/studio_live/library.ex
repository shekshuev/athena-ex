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
     |> assign(has_blocks: false)
     |> assign(course_bank_mode: false)
     |> assign(course: nil)
     |> assign(pinned_ids: MapSet.new())
     |> stream(:library_blocks, [])}
  end

  @impl true
  def handle_params(params, url, socket) do
    uri = URI.parse(url)
    current_path = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path

    course_id = params["id"]

    default_pinned = if course_id, do: "true", else: "false"

    pinned_only =
      params
      |> Map.get("pinned_only", default_pinned)
      |> to_string()
      |> then(&(&1 == "true"))

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:course_id, course_id)
      |> assign(:pinned_only, pinned_only)
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, load_blocks(socket, params)}
  end

  defp load_blocks(socket, params) do
    search = Map.get(params, "search", "")
    type = Map.get(params, "type", "all")
    tag = Map.get(params, "tag", "")

    flop_filters = build_flop_filters(search, type, tag)

    flop_params =
      params
      |> Map.merge(%{"filters" => flop_filters})
      |> Map.put("course_id", params["id"])
      |> Map.put("pinned_only", socket.assigns.pinned_only)

    case Content.list_library_blocks(socket.assigns.current_user, flop_params) do
      {:ok, {blocks, meta}} ->
        socket
        |> assign(meta: meta)
        |> assign(search: search)
        |> assign(type_filter: type)
        |> assign(tag_filter: tag)
        |> assign(has_blocks: blocks != [])
        |> stream(:library_blocks, blocks, reset: true)

      {:error, _meta} ->
        socket
        |> assign(search: search, type_filter: type, tag_filter: tag, has_blocks: false)
        |> stream(:library_blocks, [], reset: true)
    end
  end

  defp apply_action(socket, :course_library, %{"id" => course_id}) do
    case Content.get_course(socket.assigns.current_user, course_id) do
      {:ok, course} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Athena.PubSub, "course_library:#{course.id}")
        end

        pinned_blocks =
          Content.list_course_workspace_blocks(socket.assigns.current_user, course.id)

        pinned_ids = MapSet.new(Enum.map(pinned_blocks, & &1.id))

        socket
        |> assign(page_title: gettext("Course Bank: %{title}", title: course.title))
        |> assign(library_block: nil)
        |> assign(course_bank_mode: true, course: course, pinned_ids: pinned_ids)

      _ ->
        socket
        |> put_flash(:error, gettext("Course not found or access denied."))
        |> push_navigate(to: ~p"/studio/courses")
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
  def handle_event("update_filters", params, socket) do
    overrides = %{
      "search" => params["search"] || "",
      "type" => params["type"] || "all",
      "tag" => params["tag"] || "",
      "pinned_only" => params["pinned_only"] == "true",
      "page" => 1
    }

    query_params = build_query_params(socket.assigns, overrides)

    target_path =
      if socket.assigns.course_bank_mode do
        ~p"/studio/courses/#{socket.assigns.course.id}/library?#{query_params}"
      else
        ~p"/studio/library?#{query_params}"
      end

    {:noreply, push_patch(socket, to: target_path)}
  end

  def handle_event("reset_filters", _params, socket) do
    target_path =
      if socket.assigns.course_bank_mode do
        ~p"/studio/courses/#{socket.assigns.course.id}/library"
      else
        ~p"/studio/library"
      end

    {:noreply, push_patch(socket, to: target_path)}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})

    target_path =
      if socket.assigns.course_bank_mode do
        ~p"/studio/courses/#{socket.assigns.course.id}/library?#{params}"
      else
        ~p"/studio/library?#{params}"
      end

    {:noreply, push_patch(socket, to: target_path)}
  end

  def handle_event("delete_click", %{"id" => id}, socket) do
    {:ok, block} = Content.get_library_block(socket.assigns.current_user, id)

    if block.owner_id == socket.assigns.current_user.id or
         Identity.can?(socket.assigns.current_user, "library.delete", block) do
      {:noreply, assign(socket, block_to_delete: block)}
    else
      target_path =
        if socket.assigns.course_bank_mode do
          ~p"/studio/courses/#{socket.assigns.course.id}/library"
        else
          ~p"/studio/library"
        end

      {:noreply,
       socket
       |> put_flash(:error, gettext("Only the owner can delete this template."))
       |> push_patch(to: target_path)}
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

  def handle_event("toggle_pin", %{"id" => block_id}, socket) do
    if socket.assigns.course_bank_mode do
      course_id = socket.assigns.course.id
      pinned_ids = socket.assigns.pinned_ids

      if MapSet.member?(pinned_ids, block_id) do
        case Content.unpin_library_block(socket.assigns.current_user, course_id, block_id) do
          {:ok, _} ->
            {:noreply, assign(socket, pinned_ids: MapSet.delete(pinned_ids, block_id))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to unpin block."))}
        end
      else
        case Content.pin_library_block(socket.assigns.current_user, course_id, block_id) do
          {:ok, _} ->
            {:noreply, assign(socket, pinned_ids: MapSet.put(pinned_ids, block_id))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to pin block."))}
        end
      end
    else
      {:noreply, socket}
    end
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
    socket =
      if socket.assigns.course_bank_mode do
        pinned_blocks =
          Content.list_course_workspace_blocks(
            socket.assigns.current_user,
            socket.assigns.course.id
          )

        assign(socket, pinned_ids: MapSet.new(Enum.map(pinned_blocks, & &1.id)))
      else
        socket
      end

    params = build_query_params(socket.assigns, %{})
    {:noreply, load_blocks(socket, params)}
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
    <span class="badge badge-sm font-bold border border-base-200 bg-base-100 text-base-content/70 uppercase tracking-widest text-[10px]">
      {Atom.to_string(@type) |> String.replace("_", " ")}
    </span>
    """
  end

  defp build_flop_filters(search, type, tag) do
    filters = []

    filters =
      if search != "",
        do: [%{"field" => "title", "op" => "ilike_and", "value" => search} | filters],
        else: filters

    filters =
      if type in ["", "all"],
        do: filters,
        else: [%{"field" => "type", "op" => "==", "value" => type} | filters]

    tags_list =
      (tag || "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    filters =
      Enum.reduce(tags_list, filters, fn t, acc ->
        [%{"field" => "tags", "op" => "contains", "value" => t} | acc]
      end)

    filters
    |> Enum.with_index(fn filter, index -> {Integer.to_string(index), filter} end)
    |> Map.new()
  end

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

    stringified_overrides = Map.new(overrides, fn {k, v} -> {to_string(k), v} end)

    %{
      "search" => assigns.search,
      "type" => assigns.type_filter,
      "tag" => assigns.tag_filter,
      "pinned_only" => to_string(assigns.pinned_only),
      "page" => meta.current_page,
      "page_size" => meta.page_size,
      "order_by" => order_by,
      "order_directions" => order_directions
    }
    |> Map.merge(stringified_overrides)
    |> Enum.reject(fn
      {_, v} when is_list(v) -> v == []
      {"pinned_only", _v} -> not Map.get(assigns, :course_bank_mode, false)
      {_, v} -> v in [nil, "", "all"]
    end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-display font-bold text-base-content">{gettext("Library")}</h1>
          <p class="text-base-content/60">
            <%= if @course_bank_mode do %>
              {gettext("Toggle switches to pin or unpin questions for this course's assessments.")}
            <% else %>
              {gettext("Manage reusable content templates and quiz questions.")}
            <% end %>
          </p>
        </div>
        <div class="flex gap-2">
          <.link
            :if={@course_bank_mode}
            navigate={~p"/studio/courses/#{@course.id}/builder"}
            class="btn btn-outline"
          >
            <.icon name="hero-arrow-left" class="size-5" />
            {gettext("Back to Builder")}
          </.link>

          <.button
            :if={Identity.can?(@current_user, "library.create")}
            patch={~p"/studio/library/new?#{build_query_params(assigns, %{})}"}
            class="btn btn-primary"
          >
            <.icon name="hero-plus" class="size-5" />
            {gettext("Create Template")}
          </.button>
        </div>
      </div>

      <div class="bg-base-100 border border-base-200 rounded-box p-4 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="font-bold text-sm uppercase tracking-wider opacity-70">{gettext("Filters")}</h2>
          <button
            phx-click="reset_filters"
            type="button"
            class="btn btn-ghost btn-xs text-base-content/60 hover:text-error transition-colors"
          >
            <.icon name="hero-arrow-path" class="size-3 mr-1" />
            {gettext("Reset All")}
          </button>
        </div>

        <form phx-change="update_filters" phx-submit="update_filters" class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
            <.input
              type="text"
              name="search"
              value={@search}
              label={gettext("Template Title")}
              placeholder={gettext("Search templates...")}
              phx-debounce="500"
            />
            <.input
              type="select"
              name="type"
              value={@type_filter}
              options={[
                {gettext("All Types"), "all"},
                {gettext("Text Block"), "text"},
                {gettext("Code Sandbox"), "code"},
                {gettext("Quiz Question"), "quiz_question"},
                {gettext("Assessment Session"), "quiz_exam"},
                {gettext("Image"), "image"},
                {gettext("Video"), "video"},
                {gettext("Files & Materials"), "attachment"},
                {gettext("File Assignment"), "file_assignment"}
              ]}
              label={gettext("Block Type")}
            />
            <.input
              type="text"
              name="tag"
              value={@tag_filter}
              label={gettext("Tags (comma separated)")}
              placeholder={gettext("e.g. math, exam")}
              phx-debounce="500"
            />
            <div class="flex flex-col justify-end pb-2">
              <.input
                :if={@course_bank_mode}
                type="checkbox"
                name="pinned_only"
                value="true"
                label={gettext("Only Course Library")}
                class="checkbox checkbox-primary checkbox-sm"
                phx-debounce="500"
              />
            </div>
          </div>
        </form>
      </div>

      <div
        :if={not @has_blocks}
        class="text-center py-24 px-6 border border-dashed border-base-300 rounded-box mt-4"
      >
        <.icon name="hero-archive-box" class="size-16 text-base-content/20 mb-4 mx-auto" />
        <h3 class="text-xl font-bold text-base-content">
          {gettext("No templates found")}
        </h3>
        <p class="text-base-content/60 mt-2 max-w-sm mx-auto text-sm">
          {gettext("No library blocks match your search or filter criteria.")}
        </p>
      </div>

      <% path_fn = fn overrides ->
        if assigns.course_bank_mode do
          ~p"/studio/courses/#{assigns.course.id}/library?#{build_query_params(assigns, overrides)}"
        else
          ~p"/studio/library?#{build_query_params(assigns, overrides)}"
        end
      end %>

      <div :if={@has_blocks}>
        <.table id="library-blocks" rows={@streams.library_blocks} meta={@meta} path_fn={path_fn}>
          <:col :let={{_id, block}} :if={@course_bank_mode} label={gettext("In Course")}>
            <% info = block_badges(block, @current_user) %>
            <% is_course_owner = @course && @course.owner_id == @current_user.id %>
            <% can_toggle =
              is_course_owner or info.role in [:owner, :writer] or
                Identity.can?(@current_user, "library.update", block) %>

            <.input
              :if={can_toggle}
              type="checkbox"
              name={"pin_#{block.id}"}
              value={MapSet.member?(@pinned_ids, block.id)}
              phx-click="toggle_pin"
              phx-value-id={block.id}
              class="checkbox checkbox-primary checkbox-sm"
            />

            <.input
              :if={not can_toggle}
              type="checkbox"
              name={"pin_#{block.id}"}
              value={MapSet.member?(@pinned_ids, block.id)}
              disabled
              class="checkbox checkbox-primary checkbox-sm opacity-50 cursor-not-allowed"
              title={gettext("Only block owner or course owner can unpin this.")}
            />
          </:col>

          <:col :let={{_id, block}} label={gettext("Title")} sort="title">
            <div class="flex flex-col gap-1 items-start">
              <span class="font-bold">{block.title}</span>
              <.access_badges info={block_badges(block, @current_user)} />
            </div>
          </:col>

          <:col :let={{_id, block}} label={gettext("Type")} sort="type">
            <.type_badge type={block.type} />
          </:col>

          <:col :let={{_id, block}} label={gettext("Tags")}>
            <div class="flex flex-wrap gap-1">
              <span :for={tag <- block.tags || []} class="badge badge-xs badge-neutral">
                {tag}
              </span>
              <span :if={(block.tags || []) == []} class="text-xs opacity-40 italic">
                {gettext("No tags")}
              </span>
            </div>
          </:col>

          <:col :let={{_id, block}} label={gettext("Created At")} sort="inserted_at">
            <span class="text-sm opacity-60">{Calendar.strftime(block.inserted_at, "%d.%m.%Y")}</span>
          </:col>

          <:action :let={{_id, block}}>
            <% info = block_badges(block, @current_user) %>
            <% can_edit =
              info.role in [:owner, :writer] or Identity.can?(@current_user, "library.update", block) %>
            <% is_pinned = @course_bank_mode && MapSet.member?(@pinned_ids, block.id) %>

            <% can_view = can_edit or info.role == :reader or info.is_public or is_pinned %>

            <% is_pinned_anywhere =
              (Ecto.assoc_loaded?(block.course_library_blocks) && block.course_library_blocks != []) or
                is_pinned %>

            <div class="flex justify-end gap-2">
              <.button
                :if={can_view}
                navigate={~p"/studio/library/#{block.id}/editor?#{[return_to: @current_path]}"}
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
                patch={~p"/studio/library/#{block.id}/edit?#{build_query_params(assigns, %{})}"}
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
                :if={
                  (info.role == :owner or Identity.can?(@current_user, "library.delete", block)) and
                    not is_pinned_anywhere
                }
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
          <.pagination meta={@meta} path_fn={path_fn} />
        </div>
      </div>

      <.slide_over
        id="library-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(~p"/studio/library?#{build_query_params(assigns, %{})}")}
      >
        <.live_component
          :if={@library_block}
          module={LibraryFormComponent}
          id={@library_block.id || :new}
          action={@live_action}
          library_block={@library_block}
          current_user={@current_user}
          patch={~p"/studio/library?#{build_query_params(assigns, %{})}"}
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
