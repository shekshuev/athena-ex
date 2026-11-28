defmodule AthenaWeb.StudioLive.Library do
  @moduledoc """
  LiveView for managing reusable content templates (Library Blocks).
  Displays templates in a table format with contextual access controls.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.LibraryBlock
  alias Athena.Identity
  alias AthenaWeb.StudioLive.{LibraryFormComponent, LibraryShareComponent, MediaUploadComponent}

  on_mount {AthenaWeb.Hooks.Permission, "library.read"}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Athena.PubSub, "user_library:#{socket.assigns.current_user.id}")
      Phoenix.PubSub.subscribe(Athena.PubSub, "public_library")
      Phoenix.PubSub.subscribe(Athena.PubSub, "library_access")
    end

    {:ok,
     socket
     |> assign(block_to_delete: nil)
     |> assign(block_to_share: nil)
     |> assign(has_blocks: false)
     |> assign(selected_ids: MapSet.new(), page_ids: MapSet.new())
     |> assign(export_open: false, export_summary: nil, export_error: nil)
     |> assign(import_open: false, import_result: nil, import_error: nil)
     |> assign(import_form: to_form(%{"format" => "moodle_xml"}, as: :import))
     |> allow_upload(:questions,
       accept: ~w(.txt .gift .xml),
       max_entries: 1,
       max_file_size: 5_000_000
     )
     |> stream(:import_skipped, [])
     |> assign(
       export_form: to_form(%{"scope" => "filtered", "format" => "moodle_xml"}, as: :export)
     )
     |> assign(course_library_mode: false)
     |> assign(course: nil, can_edit_course: false, block_access: %{})
     |> assign(pinned_ids: MapSet.new())
     |> assign(pinnable_ids: MapSet.new())
     |> stream(:library_blocks, [])}
  end

  @impl true
  def handle_params(params, url, socket) do
    uri = URI.parse(url)
    current_path = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path

    course_id = library_course_id(socket.assigns.live_action, params)

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
      |> load_course_bank(course_id)
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, load_blocks(socket, params)}
  end

  defp load_blocks(socket, params) do
    search = Map.get(params, "search", "")
    type = Map.get(params, "type", "all")
    tag = Map.get(params, "tag", "")

    flop_params =
      params
      |> Map.put("course_id", socket.assigns.course_id)
      |> Map.put("pinned_only", socket.assigns.pinned_only)
      |> Content.library_filter_params()

    case Content.list_library_blocks(socket.assigns.current_user, flop_params) do
      {:ok, {blocks, meta}} ->
        socket
        |> assign(meta: meta, page_ids: MapSet.new(Enum.map(blocks, & &1.id)))
        |> assign(
          block_access: Content.library_blocks_access(socket.assigns.current_user, blocks)
        )
        |> assign(search: search)
        |> assign(type_filter: type)
        |> assign(tag_filter: tag)
        |> assign(has_blocks: blocks != [])
        |> assign(pinnable_ids: pinnable_ids(socket, blocks))
        |> stream(:library_blocks, blocks, reset: true)

      {:error, _meta} ->
        socket
        |> assign(search: search, type_filter: type, tag_filter: tag, has_blocks: false)
        |> assign(pinnable_ids: MapSet.new(), page_ids: MapSet.new(), block_access: %{})
        |> stream(:library_blocks, [], reset: true)
    end
  end

  # Ids of the blocks on this page the current user is actually allowed to
  # pin/unpin - mirrors the `can_toggle` check the "In Course" column itself
  # already does per row - so the header's select-all checkbox only ever
  # offers to touch blocks a bulk toggle could actually change.
  defp pinnable_ids(%{assigns: %{can_edit_course: true}}, blocks),
    do: MapSet.new(Enum.map(blocks, & &1.id))

  defp pinnable_ids(_socket, _blocks), do: MapSet.new()

  defp all_pinned?(pinnable_ids, _pinned_ids) when pinnable_ids == %MapSet{}, do: false
  defp all_pinned?(pinnable_ids, pinned_ids), do: MapSet.subset?(pinnable_ids, pinned_ids)

  defp pin_all_targets(pinnable_ids, pinned_ids, true = _select_all?),
    do: MapSet.difference(pinnable_ids, pinned_ids)

  defp pin_all_targets(pinnable_ids, pinned_ids, false = _select_all?),
    do: MapSet.intersection(pinnable_ids, pinned_ids)

  defp apply_bulk_pin(block_id, {pinned_ids, failures}, socket, select_all?) do
    course_id = socket.assigns.course.id
    user = socket.assigns.current_user

    result =
      if select_all?,
        do: Content.pin_library_block(user, course_id, block_id),
        else: Content.unpin_library_block(user, course_id, block_id)

    case result do
      {:ok, _} -> {toggle_membership(pinned_ids, block_id, select_all?), failures}
      {:error, _} -> {pinned_ids, failures + 1}
    end
  end

  defp toggle_membership(mapset, id, true = _member?), do: MapSet.put(mapset, id)
  defp toggle_membership(mapset, id, false = _member?), do: MapSet.delete(mapset, id)

  defp library_course_id(:course_library, params), do: params["id"]
  defp library_course_id(:new, params), do: params["id"]
  defp library_course_id(:edit, %{"block_id" => _} = params), do: params["id"]
  defp library_course_id(_action, _params), do: nil

  defp load_course_bank(socket, nil),
    do:
      assign(socket,
        course: nil,
        course_library_mode: false,
        can_edit_course: false,
        pinned_ids: MapSet.new()
      )

  defp load_course_bank(socket, course_id) do
    case Content.get_course(socket.assigns.current_user, course_id) do
      {:ok, course} ->
        blocks = Content.list_course_workspace_blocks(socket.assigns.current_user, course.id)

        assign(socket,
          course: course,
          course_library_mode: true,
          can_edit_course: Content.can_edit_course?(socket.assigns.current_user, course),
          pinned_ids: MapSet.new(Enum.map(blocks, & &1.id))
        )

      _ ->
        socket
        |> assign(can_edit_course: false, pinned_ids: MapSet.new())
        |> put_flash(:error, gettext("Course not found or access denied."))
        |> push_navigate(to: ~p"/studio/courses")
    end
  end

  defp apply_action(%{assigns: %{course: nil}} = socket, :course_library, _params),
    do: assign(socket, page_title: gettext("Library"), library_block: nil)

  defp apply_action(socket, :course_library, _params),
    do:
      assign(socket,
        page_title: gettext("Course Library: %{title}", title: socket.assigns.course.title),
        library_block: nil
      )

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

  defp apply_action(socket, :edit, params) do
    id = params["block_id"] || params["id"]

    case Content.get_library_block(socket.assigns.current_user, id) do
      {:ok, block} ->
        if Content.can_edit_library_block?(socket.assigns.current_user, block) do
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
      if socket.assigns.course_library_mode do
        ~p"/studio/courses/#{socket.assigns.course.id}/library?#{query_params}"
      else
        ~p"/studio/library?#{query_params}"
      end

    {:noreply, push_patch(socket, to: target_path)}
  end

  def handle_event("reset_filters", _params, socket) do
    target_path =
      if socket.assigns.course_library_mode do
        ~p"/studio/courses/#{socket.assigns.course.id}/library"
      else
        ~p"/studio/library"
      end

    {:noreply, push_patch(socket, to: target_path)}
  end

  def handle_event("update_page_size", %{"page_size" => size}, socket) do
    params = build_query_params(socket.assigns, %{"page_size" => size, "page" => 1})

    target_path =
      if socket.assigns.course_library_mode do
        ~p"/studio/courses/#{socket.assigns.course.id}/library?#{params}"
      else
        ~p"/studio/library?#{params}"
      end

    {:noreply, push_patch(socket, to: target_path)}
  end

  def handle_event("open_import", _params, socket) do
    if Identity.can?(socket.assigns.current_user, "library.create") do
      {:noreply,
       socket
       |> clear_flash()
       |> assign(import_open: true, import_result: nil, import_error: nil)
       |> stream(:import_skipped, [], reset: true)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to create templates."))}
    end
  end

  def handle_event("close_import", _params, socket) do
    socket =
      Enum.reduce(
        socket.assigns.uploads.questions.entries,
        socket,
        &cancel_upload(&2, :questions, &1.ref)
      )

    {:noreply, assign(socket, import_open: false)}
  end

  def handle_event("validate_import", %{"import" => params}, socket) do
    {:noreply,
     socket
     |> assign(import_form: to_form(params, as: :import), import_error: nil, import_result: nil)
     |> stream(:import_skipped, [], reset: true)}
  end

  def handle_event("cancel_import_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :questions, ref)}

  def handle_event("import_questions", %{"import" => params}, socket) do
    result = import_upload(socket, params["format"])
    {:noreply, finish_import(socket, result)}
  end

  def handle_event("toggle_export_selection", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    if MapSet.member?(socket.assigns.page_ids, id) do
      socket =
        assign(socket,
          selected_ids: toggle_membership(selected, id, not MapSet.member?(selected, id))
        )

      {:noreply, load_blocks(socket, build_query_params(socket.assigns, %{}))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_export_page", _params, socket) do
    selected = socket.assigns.selected_ids
    page = socket.assigns.page_ids

    selected =
      if MapSet.subset?(page, selected),
        do: MapSet.difference(selected, page),
        else: MapSet.union(selected, page)

    socket = assign(socket, selected_ids: selected)
    {:noreply, load_blocks(socket, build_query_params(socket.assigns, %{}))}
  end

  def handle_event("clear_export_selection", _params, socket) do
    socket = assign(socket, selected_ids: MapSet.new())
    {:noreply, load_blocks(socket, build_query_params(socket.assigns, %{}))}
  end

  def handle_event("open_export", _params, socket) do
    scope = if MapSet.size(socket.assigns.selected_ids) > 0, do: "selected", else: "filtered"

    {:noreply,
     socket
     |> assign(export_open: true)
     |> preview_export(%{"scope" => scope, "format" => "moodle_xml"})}
  end

  def handle_event("preview_export", %{"export" => params}, socket) do
    {:noreply, preview_export(socket, params)}
  end

  def handle_event("close_export", _params, socket),
    do: {:noreply, assign(socket, export_open: false)}

  def handle_event("delete_click", %{"id" => id}, socket) do
    with {:ok, block} <- Content.get_library_block(socket.assigns.current_user, id),
         true <- Content.library_block_access(socket.assigns.current_user, block).can_delete do
      {:noreply, assign(socket, block_to_delete: block)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Only the owner can delete this template."))}
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
        if Content.library_block_access(socket.assigns.current_user, block).can_manage do
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

  def handle_event(
        "toggle_pin",
        %{"id" => block_id},
        %{assigns: %{course_library_mode: true}} = socket
      ) do
    course_id = socket.assigns.course.id
    pinned_ids = socket.assigns.pinned_ids
    currently_pinned? = MapSet.member?(pinned_ids, block_id)

    result =
      if currently_pinned? do
        Content.unpin_library_block(socket.assigns.current_user, course_id, block_id)
      else
        Content.pin_library_block(socket.assigns.current_user, course_id, block_id)
      end

    case result do
      {:ok, _} ->
        new_pinned_ids = toggle_membership(pinned_ids, block_id, !currently_pinned?)
        {:noreply, assign(socket, pinned_ids: new_pinned_ids)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update block."))}
    end
  end

  def handle_event("toggle_pin", _params, socket), do: {:noreply, socket}

  # Toggles every togglable block on the current page at once: pins whatever
  # isn't pinned yet unless everything already is, in which case it unpins
  # the lot instead - the standard "select all" header checkbox behavior.
  def handle_event(
        "toggle_pin_all",
        _params,
        %{assigns: %{course_library_mode: true}} = socket
      ) do
    select_all? = not all_pinned?(socket.assigns.pinnable_ids, socket.assigns.pinned_ids)
    targets = pin_all_targets(socket.assigns.pinnable_ids, socket.assigns.pinned_ids, select_all?)

    {pinned_ids, failures} =
      Enum.reduce(
        targets,
        {socket.assigns.pinned_ids, 0},
        &apply_bulk_pin(&1, &2, socket, select_all?)
      )

    socket = assign(socket, :pinned_ids, pinned_ids)

    socket =
      if failures > 0 do
        put_flash(socket, :error, gettext("Failed to update %{count} block(s).", count: failures))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_pin_all", _params, socket), do: {:noreply, socket}

  def handle_event("copy_block", %{"id" => id}, socket) do
    with {:ok, block} <- Content.get_library_block(socket.assigns.current_user, id),
         {:ok, _copy} <- duplicate_block(socket, block) do
      socket =
        socket
        |> put_flash(:info, gettext("Template duplicated successfully"))
        |> load_blocks(build_query_params(socket.assigns, %{}))

      {:noreply, socket}
    else
      {:error, :forbidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You do not have permission to duplicate this template.")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to duplicate template"))}
    end
  end

  defp import_upload(socket, format) do
    with true <- Identity.can?(socket.assigns.current_user, "library.create"),
         {[_entry], []} <- uploaded_entries(socket, :questions) do
      [data] =
        consume_uploaded_entries(socket, :questions, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)

      Content.import_library_questions(socket.assigns.current_user, data, format)
    else
      false -> {:error, :forbidden}
      _ -> {:error, :missing_file}
    end
  end

  defp finish_import(socket, {:ok, result}) do
    socket
    |> clear_flash()
    |> assign(import_open: false, import_result: Map.drop(result, [:skipped]), import_error: nil)
    |> put_flash(
      if(result.imported > 0, do: :info, else: :error),
      gettext("Imported: %{imported}. Skipped: %{skipped}.",
        imported: result.imported,
        skipped: result.skipped_count
      )
    )
    |> stream(:import_skipped, result.skipped, reset: true)
    |> load_blocks(build_query_params(socket.assigns, %{}))
  end

  defp finish_import(socket, {:error, reason}),
    do:
      socket
      |> clear_flash()
      |> assign(import_error: import_error(reason), import_result: nil)
      |> stream(:import_skipped, [], reset: true)

  defp import_error(:forbidden), do: gettext("You don't have permission to create templates.")

  defp import_error(:missing_file),
    do: gettext("Choose a file and wait for the upload to finish.")

  defp import_error(:file_too_large), do: gettext("The file must be no larger than 5 MB.")
  defp import_error(:too_many_questions), do: gettext("Import up to 2000 questions at a time.")
  defp import_error(:no_questions), do: gettext("No questions found in the file.")

  defp import_error(_reason),
    do: gettext("Could not read the file. Check the selected format and UTF-8 encoding.")

  defp import_skip_reason(:unsupported_type), do: gettext("Unsupported question type")
  defp import_skip_reason(:unsupported_format), do: gettext("Unsupported text or answer format")

  defp import_skip_reason(:embedded_files),
    do: gettext("Embedded files or attachments are not supported")

  defp import_skip_reason(:answer_pattern),
    do: gettext("Answer rules cannot be represented in Athena")

  defp import_skip_reason(:fractional_points),
    do: gettext("Question points must be a positive integer")

  defp import_skip_reason(:unsupported_content), do: gettext("Unsupported rich-text content")
  defp import_skip_reason(_reason), do: gettext("Invalid or incomplete question")

  defp preview_export(socket, params) do
    case Content.preview_library_export(
           socket.assigns.current_user,
           export_params(socket.assigns, params["scope"])
         ) do
      {:ok, summary} ->
        assign(socket,
          export_form: to_form(params, as: :export),
          export_summary: summary,
          export_error: nil
        )

      {:error, _} ->
        assign(socket,
          export_form: to_form(params, as: :export),
          export_summary: nil,
          export_error:
            gettext(
              "Some selected blocks are no longer available. Clear the selection and try again."
            )
        )
    end
  end

  defp export_params(assigns, scope) do
    %{
      "scope" => scope,
      "ids" => MapSet.to_list(assigns.selected_ids),
      "search" => assigns.search,
      "type" => assigns.type_filter,
      "tag" => assigns.tag_filter,
      "course_id" => if(assigns.course_library_mode, do: assigns.course.id, else: nil),
      "pinned_only" => to_string(assigns.pinned_only),
      "order_by" => assigns.meta.flop.order_by |> List.wrap() |> Enum.map(&to_string/1),
      "order_directions" =>
        assigns.meta.flop.order_directions |> List.wrap() |> Enum.map(&to_string/1)
    }
  end

  defp duplicate_block(%{assigns: %{course_library_mode: true}} = socket, block),
    do:
      Content.duplicate_library_block_for_course(
        socket.assigns.current_user,
        socket.assigns.course.id,
        block.id
      )

  defp duplicate_block(socket, block),
    do: Content.duplicate_library_block(socket.assigns.current_user, block)

  @impl true
  def handle_info({LibraryFormComponent, {:saved, _block}}, socket) do
    {:noreply, load_blocks(socket, build_query_params(socket.assigns, %{}))}
  end

  def handle_info({LibraryShareComponent, {:updated, block}}, socket) do
    socket =
      if socket.assigns.block_to_share && socket.assigns.block_to_share.id == block.id do
        assign(socket, block_to_share: block)
      else
        socket
      end

    {:noreply, load_blocks(socket, build_query_params(socket.assigns, %{}))}
  end

  @impl true
  def handle_info(:refresh_library, socket) do
    socket = load_course_bank(socket, socket.assigns.course_id)
    params = build_query_params(socket.assigns, %{})
    {:noreply, load_blocks(socket, params)}
  end

  defp block_badges(block, user, access) do
    %{
      role: if(block.owner_id == user.id, do: :owner, else: access.role),
      is_public: block.is_public,
      shares_count: access.shares_count
    }
  end

  defp access_badges(assigns) do
    ~H"""
    <div class="flex gap-1 items-center">
      <.badge :if={@info.role != :none} tone={role_tone(@info.role)} class="uppercase shrink-0">
        {Atom.to_string(@info.role)}
      </.badge>

      <.badge :if={@info.is_public} tone="neutral" class="uppercase shrink-0">
        <.icon name="hero-eye" class="size-3 mr-1" />
        {gettext("Public")}
      </.badge>

      <.badge
        :if={!@info.is_public and @info.shares_count > 0 and @info.role == :owner}
        tone="info"
        class="shrink-0"
      >
        <.icon name="hero-users" class="size-3 mr-1" />
        {@info.shares_count}
      </.badge>
    </div>
    """
  end

  defp role_tone(:owner), do: "primary"
  defp role_tone(:writer), do: "secondary"
  defp role_tone(:reader), do: "accent"

  defp type_badge(assigns) do
    ~H"""
    <.badge tone="neutral" class="uppercase tracking-widest text-[10px]">
      {if @type == :multicode,
        do: gettext("Multicode"),
        else: Atom.to_string(@type) |> String.replace("_", " ")}
    </.badge>
    """
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
      {"pinned_only", _v} -> not Map.get(assigns, :course_library_mode, false)
      {_, v} -> v in [nil, "", "all"]
    end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={
      @course_library_mode && "fixed inset-0 z-50 bg-base-100 overflow-y-auto p-4 pb-20 sm:p-8"
    }>
      <.page_container size="wide">
        <div class="space-y-6">
          <div class="flex flex-col gap-4 sm:flex-row sm:justify-between sm:items-center">
            <div class="flex items-center gap-4">
              <.link
                :if={@course_library_mode}
                navigate={~p"/studio/courses/#{@course.id}/builder"}
                class="btn btn-ghost btn-sm btn-square rounded-sm hover:bg-base-200"
                title={gettext("Back to Builder")}
              >
                <.icon name="hero-arrow-left" class="size-5" />
              </.link>

              <div>
                <h1 class="text-2xl font-display font-bold text-base-content">
                  {@page_title}
                </h1>
                <p class="text-base-content/60">
                  <%= if @course_library_mode do %>
                    {gettext(
                      "Toggle checkboxes to pin or unpin questions for this course's assessments."
                    )}
                  <% else %>
                    {gettext("Manage reusable content templates and quiz questions.")}
                  <% end %>
                </p>
              </div>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <.button
                :if={Identity.can?(@current_user, "library.create")}
                id="library-import-open"
                type="button"
                phx-click="open_import"
                class="btn btn-outline"
              >
                <.icon name="hero-arrow-up-tray" class="size-5" />
                {gettext("Import questions")}
              </.button>
              <.button
                id="library-export-open"
                type="button"
                phx-click="open_export"
                class="btn btn-outline"
              >
                <.icon name="hero-arrow-down-tray" class="size-5" />
                {gettext("Export questions")}
              </.button>
              <% new_patch =
                if @course_library_mode,
                  do:
                    ~p"/studio/courses/#{@course.id}/library/new?#{build_query_params(assigns, %{})}",
                  else: ~p"/studio/library/new?#{build_query_params(assigns, %{})}" %>
              <.button
                :if={Identity.can?(@current_user, "library.create")}
                patch={new_patch}
                class="btn btn-primary"
              >
                <.icon name="hero-plus" class="size-5" />
                <span class="hidden sm:inline">{gettext("Create Template")}</span>
                <span class="sm:hidden">{gettext("Create")}</span>
              </.button>
            </div>
          </div>

          <div class="bg-base-100 border border-base-200 rounded-box p-4 mb-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="font-bold text-sm uppercase tracking-wider opacity-70">
                {gettext("Filters")}
              </h2>
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
                    {gettext("Multicode"), "multicode"},
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
                    :if={@course_library_mode}
                    type="checkbox"
                    name="pinned_only"
                    value={@pinned_only}
                    label={gettext("Only Course Library")}
                    class="checkbox checkbox-primary checkbox-sm"
                    phx-debounce="500"
                  />
                </div>
              </div>
            </form>
          </div>

          <div
            id="library-import-report"
            class={["space-y-3", is_nil(@import_result) && "hidden"]}
            aria-live="polite"
          >
            <div
              :if={@import_result}
              id="library-import-result"
              class="rounded-lg border border-base-300 p-3 text-sm"
            >
              {gettext("Imported: %{imported}. Skipped: %{skipped}.",
                imported: @import_result.imported,
                skipped: @import_result.skipped_count
              )}
              <.link navigate={~p"/studio/library"} class="underline ml-1">
                {gettext("Open library")}
              </.link>
            </div>
            <div
              id="library-import-skipped"
              phx-update="stream"
              class="max-h-64 overflow-y-auto space-y-2 text-sm"
            >
              <p :for={{dom_id, item} <- @streams.import_skipped} id={dom_id}>
                {gettext("Question %{number}: %{title} – %{reason}",
                  number: item.id,
                  title: item.title,
                  reason: import_skip_reason(item.reason)
                )}
              </p>
            </div>
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
            if assigns.course_library_mode do
              ~p"/studio/courses/#{assigns.course.id}/library?#{build_query_params(assigns, overrides)}"
            else
              ~p"/studio/library?#{build_query_params(assigns, overrides)}"
            end
          end %>

          <div :if={@has_blocks}>
            <div class="flex flex-wrap items-center gap-3 mb-3">
              <.input
                id="library-export-select-page"
                type="checkbox"
                name="export_select_page"
                checked={MapSet.subset?(@page_ids, @selected_ids)}
                phx-click="select_export_page"
                label={gettext("Select this page for export")}
              />
              <span id="library-export-selection-count" class="text-sm text-base-content/60">
                {gettext("Selected: %{count}", count: MapSet.size(@selected_ids))}
              </span>
              <button
                :if={MapSet.size(@selected_ids) > 0}
                id="library-export-clear"
                type="button"
                phx-click="clear_export_selection"
                class="text-sm underline hover:text-primary"
              >
                {gettext("Clear selection")}
              </button>
            </div>
            <label
              :if={@course_library_mode && @pinnable_ids != MapSet.new()}
              class="flex items-center gap-2 mb-3 cursor-pointer select-none w-fit"
            >
              <input
                type="checkbox"
                checked={all_pinned?(@pinnable_ids, @pinned_ids)}
                phx-click="toggle_pin_all"
                class="checkbox checkbox-primary checkbox-sm"
              />
              <span class="text-sm font-bold">
                <%= if all_pinned?(@pinnable_ids, @pinned_ids) do %>
                  {gettext("Deselect all")}
                <% else %>
                  {gettext("Select all")}
                <% end %>
              </span>
              <span class="text-xs text-base-content/50 font-normal">
                {gettext("(%{pinned}/%{total} in this course)",
                  pinned: MapSet.size(MapSet.intersection(@pinnable_ids, @pinned_ids)),
                  total: MapSet.size(@pinnable_ids)
                )}
              </span>
            </label>

            <.table id="library-blocks" rows={@streams.library_blocks} meta={@meta} path_fn={path_fn}>
              <:col :let={{_id, block}} label={gettext("Select")}>
                <.input
                  id={"export-select-#{block.id}"}
                  type="checkbox"
                  name={"export_select_#{block.id}"}
                  checked={MapSet.member?(@selected_ids, block.id)}
                  phx-click="toggle_export_selection"
                  phx-value-id={block.id}
                  aria-label={gettext("Select %{title} for export", title: block.title)}
                />
              </:col>
              <:col :let={{_id, block}} :if={@course_library_mode} label={gettext("In Course")}>
                <% can_toggle = @can_edit_course %>

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
                  title={gettext("Only course editors can pin or unpin templates.")}
                />
              </:col>

              <:col :let={{_id, block}} label={gettext("Title")} sort="title">
                <div class="flex flex-col gap-1 items-start">
                  <span class="font-bold">{block.title}</span>
                  <.access_badges info={
                    block_badges(block, @current_user, Map.fetch!(@block_access, block.id))
                  } />
                </div>
              </:col>

              <:col :let={{_id, block}} label={gettext("Type")} sort="type">
                <.type_badge type={block.type} />
              </:col>

              <:col :let={{_id, block}} label={gettext("Tags")}>
                <div class="flex flex-wrap gap-1">
                  <.badge :for={tag <- block.tags || []} tone="neutral">
                    {tag}
                  </.badge>
                  <span :if={(block.tags || []) == []} class="text-xs opacity-40 italic">
                    {gettext("No tags")}
                  </span>
                </div>
              </:col>

              <:col :let={{_id, block}} label={gettext("Created At")} sort="inserted_at">
                <span class="text-sm opacity-60">
                  {TimeZones.format(block.inserted_at, "%d.%m.%Y")}
                </span>
              </:col>

              <:action :let={{_id, block}}>
                <% access = Map.fetch!(@block_access, block.id) %>
                <% can_edit = access.can_edit %>
                <% can_view = access.role != :none %>
                <% is_pinned = @course_library_mode && MapSet.member?(@pinned_ids, block.id) %>

                <% is_pinned_anywhere =
                  (Ecto.assoc_loaded?(block.course_library_blocks) &&
                     block.course_library_blocks != []) or
                    is_pinned %>

                <div class="flex justify-end gap-2">
                  <% editor_path =
                    if @course_library_mode,
                      do:
                        ~p"/studio/courses/#{@course.id}/library/#{block.id}/editor?#{build_query_params(assigns, %{})}",
                      else: ~p"/studio/library/#{block.id}/editor?#{build_query_params(assigns, %{})}" %>

                  <.button
                    :if={can_view}
                    id={"open-editor-#{block.id}"}
                    navigate={editor_path}
                    class="btn btn-primary btn-xs btn-square btn-soft"
                    title={if can_edit, do: gettext("Open Editor"), else: gettext("View Template")}
                  >
                    <.icon
                      name={if can_edit, do: "hero-wrench-screwdriver", else: "hero-eye"}
                      class="size-4"
                    />
                  </.button>

                  <% edit_patch =
                    if @course_library_mode,
                      do:
                        ~p"/studio/courses/#{@course.id}/library/#{block.id}/edit?#{build_query_params(assigns, %{})}",
                      else: ~p"/studio/library/#{block.id}/edit?#{build_query_params(assigns, %{})}" %>
                  <.button
                    :if={can_edit}
                    patch={edit_patch}
                    class="btn btn-ghost btn-xs btn-square"
                    title={gettext("Edit Metadata")}
                  >
                    <.icon name="hero-pencil-square" class="size-4" />
                  </.button>

                  <.button
                    :if={
                      can_view and Identity.can?(@current_user, "library.create") and
                        (not @course_library_mode or @can_edit_course)
                    }
                    id={"copy-block-#{block.id}"}
                    type="button"
                    phx-click="copy_block"
                    phx-value-id={block.id}
                    class="btn btn-ghost btn-xs btn-square"
                    title={
                      if @course_library_mode,
                        do: gettext("Create a copy for this course"),
                        else: gettext("Duplicate Template")
                    }
                  >
                    <.icon name="hero-square-2-stack" class="size-4" />
                  </.button>

                  <.button
                    :if={access.can_manage}
                    type="button"
                    phx-click="share_click"
                    phx-value-id={block.id}
                    class="btn btn-ghost btn-xs btn-square"
                    title={gettext("Share Access")}
                  >
                    <.icon name="hero-share" class="size-4" />
                  </.button>

                  <.button
                    :if={access.can_delete and not is_pinned_anywhere}
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
        </div>
      </.page_container>

      <% base_patch =
        if @course_library_mode,
          do: ~p"/studio/courses/#{@course.id}/library?#{build_query_params(assigns, %{})}",
          else: ~p"/studio/library?#{build_query_params(assigns, %{})}" %>
      <.slide_over
        id="library-slideover"
        show={@live_action in [:new, :edit]}
        title={@page_title}
        on_close={JS.patch(base_patch)}
      >
        <.live_component
          :if={@library_block}
          module={LibraryFormComponent}
          id={@library_block.id || :new}
          action={@live_action}
          library_block={@library_block}
          current_user={@current_user}
          patch={base_patch}
        />
      </.slide_over>

      <.modal
        id="library-import-modal"
        show={@import_open}
        title={gettext("Import questions")}
        on_cancel={JS.push("close_import")}
      >
        <.form
          for={@import_form}
          id="library-import-form"
          phx-change="validate_import"
          phx-submit="import_questions"
          class="space-y-4"
        >
          <p
            :if={@import_error}
            id="library-import-error"
            role="alert"
            class="rounded-lg border border-error/30 bg-error/10 p-3 text-sm text-error"
          >
            {@import_error}
          </p>
          <.input
            field={@import_form[:format]}
            type="select"
            label={gettext("File format")}
            options={[{"Moodle XML", "moodle_xml"}, {"GIFT", "gift"}]}
          />
          <MediaUploadComponent.file_picker
            id="library-import-picker"
            upload={@uploads.questions}
            description={gettext("Question file (UTF-8, up to 5 MB)")}
            cancel_event="cancel_import_upload"
          />
          <details id="library-import-help" class="text-sm text-base-content/70 space-y-2">
            <summary class="cursor-pointer font-medium">
              {gettext("About importing questions")}
            </summary>
            <p class="mt-2">
              {gettext(
                "Import creates new private questions in your library. Existing questions are not updated, file IDs and sharing settings are ignored. Pin imported questions to a course separately. Reimporting a file creates copies."
              )}
            </p>
            <p>
              {gettext(
                "Supported: single and multiple choice, true/false, matching, one literal exact answer, and open answers. Numerical, Cloze, calculated questions, wildcard answers, multiple accepted short answers and embedded files are skipped. Categories are ignored; question tags are preserved."
              )}
            </p>
            <p>
              {gettext(
                "Partial answer weights and penalties are not preserved: Athena grades the complete answer as correct or incorrect. XML preserves whole-number question points and case sensitivity; GIFT does not provide them. Basic HTML formatting is preserved; styles and unsupported wrappers are simplified. Images must use external HTTP(S) links, which may require access to the original site."
              )}
            </p>
          </details>
          <p class="text-sm text-base-content/70">
            {gettext(
              "LaTeX formulas remain text. Hints and answer shuffling settings are not imported. Short-answer feedback is added to the general explanation."
            )}
          </p>
          <p class="text-sm text-base-content/70">
            {gettext("Import up to 2000 questions at a time.")}
          </p>
          <.button
            id="library-import-submit"
            type="submit"
            class="btn btn-primary w-full"
            phx-disable-with={gettext("Importing...")}
            disabled={@uploads.questions.entries == [] or upload_errors(@uploads.questions) != []}
          >
            {gettext("Import questions")}
          </.button>
        </.form>
      </.modal>

      <.modal
        id="library-export-modal"
        show={@export_open}
        title={gettext("Export questions")}
        on_cancel={JS.push("close_export")}
      >
        <.form
          for={@export_form}
          id="library-export-form"
          action={~p"/studio/library/export"}
          method="post"
          target="_blank"
          phx-change="preview_export"
          class="space-y-4"
        >
          <.input
            field={@export_form[:scope]}
            type="select"
            label={gettext("Export scope")}
            options={[
              {gettext("Selected blocks (%{count})", count: MapSet.size(@selected_ids)), "selected"},
              {gettext("All blocks matching current filters (all pages)"), "filtered"}
            ]}
          />
          <.input
            field={@export_form[:format]}
            type="select"
            label={gettext("File format")}
            options={[{"Moodle XML", "moodle_xml"}, {"GIFT", "gift"}]}
          />
          <input :for={id <- @selected_ids} type="hidden" name="ids[]" value={id} />
          <input
            :for={key <- ~w(search type tag course_id pinned_only)}
            type="hidden"
            name={key}
            value={export_params(assigns, @export_form[:scope].value)[key]}
          />
          <input
            :for={value <- export_params(assigns, "filtered")["order_by"]}
            type="hidden"
            name="order_by[]"
            value={value}
          />
          <input
            :for={value <- export_params(assigns, "filtered")["order_directions"]}
            type="hidden"
            name="order_directions[]"
            value={value}
          />
          <div
            :if={@export_summary}
            id="library-export-summary"
            class="rounded-lg border border-base-300 p-3 text-sm space-y-2"
          >
            <p>
              {gettext("Blocks: %{total}. Questions to export: %{questions}.",
                total: @export_summary.total,
                questions: @export_summary.questions
              )}
            </p>
            <p :if={@export_summary.skipped > 0} id="library-export-skipped">
              {gettext(
                "%{count} blocks of other types will not be included. Exams are not expanded into questions.",
                count: @export_summary.skipped
              )}
            </p>
          </div>
          <p :if={@export_error} id="library-export-error" class="text-sm text-error">
            {@export_error}
          </p>
          <details id="library-export-help" class="text-sm text-base-content/70 space-y-2">
            <summary class="cursor-pointer font-medium">{gettext("About export formats")}</summary>
            <p class="mt-2">
              {gettext(
                "Moodle XML preserves question tags, points, case sensitivity and the open-answer editor type. GIFT preserves tags, but does not preserve points, case sensitivity or the open-answer editor type."
              )}
            </p>
            <p>
              {gettext(
                "In both formats, Moodle can award partial credit for multiple-choice and matching questions; Athena requires the complete correct answer. Matching answer labels become plain text."
              )}
            </p>
            <p>
              {gettext(
                "Images remain links in both exports and may require access to Athena. Formulas require a math filter in Moodle. Unsupported or incomplete question content stops the download instead of being silently omitted."
              )}
            </p>
          </details>
          <.button
            id="library-export-download"
            type="submit"
            class="btn btn-primary w-full"
            disabled={is_nil(@export_summary) or @export_summary.questions == 0}
          >
            {gettext("Export %{count} questions",
              count: if(@export_summary, do: @export_summary.questions, else: 0)
            )}
          </.button>
        </.form>
      </.modal>

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
