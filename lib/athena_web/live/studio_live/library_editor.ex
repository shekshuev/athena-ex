defmodule AthenaWeb.StudioLive.LibraryEditor do
  @moduledoc """
  Standalone editor for Library Blocks.
  Uses a strict two-column card UI, matching GradingDetail.
  Implements strict RBAC and real-time collaboration updates.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.LibraryBlock
  import AthenaWeb.BlockComponents

  on_mount {AthenaWeb.Hooks.Permission, "library.read"}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, block} <- Content.get_library_block(socket.assigns.current_user, id),
         role when role != :none <- determine_role(block, socket.assigns.current_user) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Athena.PubSub, "user_library:#{socket.assigns.current_user.id}")
        Phoenix.PubSub.subscribe(Athena.PubSub, "public_library")
      end

      form = to_form(LibraryBlock.changeset(block, %{}))

      {:ok,
       socket
       |> assign(
         role: role,
         page_title: gettext("Edit Template"),
         block: block,
         form: form,
         tags_string: Enum.join(block.tags || [], ", "),
         show_media_modal: false,
         upload_type: nil
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Template not found or access denied."))
         |> push_navigate(to: ~p"/studio/library")}
    end
  end

  @impl true
  def handle_info(:refresh_library, socket) do
    with {:ok, block} <-
           Content.get_library_block(socket.assigns.current_user, socket.assigns.block.id),
         new_role when new_role != :none <- determine_role(block, socket.assigns.current_user) do
      socket =
        if new_role != socket.assigns.role do
          put_flash(socket, :info, gettext("Your access level has been updated."))
        else
          socket
        end

      {:noreply, assign(socket, block: block, role: new_role)}
    else
      :none ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Your access to this template was revoked."))
         |> push_navigate(to: ~p"/studio/library")}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This template is no longer available."))
         |> push_navigate(to: ~p"/studio/library")}
    end
  end

  @impl true
  def handle_info(
        {AthenaWeb.StudioLive.MediaUploadComponent, {:saved, _block_id, media_type, results}},
        socket
      ) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        content_map = normalize_content(block.content || %{})

        new_content =
          case media_type do
            "attachment" ->
              Map.put(content_map, "files", Map.get(content_map, "files", []) ++ results)

            _ ->
              file_map = List.first(results)
              Map.put(content_map, "url", file_map["url"])
          end

        socket =
          socket
          |> assign(show_media_modal: false, upload_type: nil)
          |> put_flash(:info, gettext("Media uploaded successfully!"))

        update_and_assign(socket, block, %{"content" => new_content})

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_content", %{"content" => parsed}, socket) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        content_map = normalize_content(block.content || %{})

        new_content =
          case block.type do
            :attachment -> Map.put(content_map, "description", parsed)
            :quiz_question -> Map.put(content_map, "body", parsed)
            _ -> parsed
          end

        update_and_assign(socket, block, %{"content" => new_content})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("add_quiz_option", _, socket) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        content_map = normalize_content(block.content || %{})
        options = Map.get(content_map, "options", [])

        new_option = %{
          "id" => Ecto.UUID.generate(),
          "text" => "New Option",
          "is_correct" => false,
          "explanation" => ""
        }

        new_content = Map.put(content_map, "options", options ++ [new_option])
        update_and_assign(socket, block, %{"content" => new_content})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_quiz_option", %{"option_id" => option_id}, socket) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        content_map = normalize_content(block.content || %{})
        options = Map.get(content_map, "options", []) |> Enum.reject(&(&1["id"] == option_id))

        update_and_assign(socket, block, %{"content" => Map.put(content_map, "options", options)})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("update_quiz_content", params, socket) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        content_map = normalize_content(block.content || %{})

        content_map =
          if ans = params["correct_answer"],
            do: Map.put(content_map, "correct_answer", ans),
            else: content_map

        content_map =
          if opts = params["options"],
            do:
              Map.put(
                content_map,
                "options",
                parse_quiz_options(opts, params["correct_option_id"])
              ),
            else: content_map

        update_and_assign(socket, block, %{"content" => content_map})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_attachment", %{"url" => url}, socket) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        content_map = normalize_content(block.content || %{})
        files = Map.get(content_map, "files", []) |> Enum.reject(&(&1["url"] == url))

        update_and_assign(socket, block, %{"content" => Map.put(content_map, "files", files)})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("request_media_upload", %{"media_type" => type}, socket) do
    case can_edit?(socket) do
      true -> {:noreply, assign(socket, show_media_modal: true, upload_type: type)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_media_upload", _, socket) do
    case can_edit?(socket) do
      true -> {:noreply, assign(socket, show_media_modal: false, upload_type: nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("update_meta", %{"library_block" => params} = form_data, socket) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        tags_string = Map.get(form_data, "tags_string", socket.assigns.tags_string)

        params =
          if Map.has_key?(form_data, "tags_string") do
            tags =
              tags_string
              |> String.split(",", trim: true)
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

            Map.put(params, "tags", tags)
          else
            params
          end

        content_map = normalize_content(block.content || %{})
        content_overrides = Map.get(params, "content", %{})

        content_overrides =
          content_map
          |> apply_quiz_meta_overrides(content_overrides)
          |> apply_exam_meta_overrides(block.type, form_data)

        final_content = Map.merge(content_map, content_overrides)
        final_params = Map.put(params, "content", final_content)

        case Content.update_library_block(socket.assigns.current_user, block, final_params) do
          {:ok, updated_block} ->
            {:noreply,
             assign(socket,
               block: updated_block,
               form: to_form(LibraryBlock.changeset(updated_block, %{})),
               tags_string: tags_string
             )}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp update_and_assign(socket, block, params) do
    case Content.update_library_block(socket.assigns.current_user, block, params) do
      {:ok, updated} ->
        {:noreply, assign(socket, block: updated)}

      {:error, changeset} ->
        in_memory_block = Ecto.Changeset.apply_changes(changeset)
        {:noreply, assign(socket, block: in_memory_block)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        block_mode: if(assigns.role in [:owner, :writer], do: :edit, else: :preview)
      )

    ~H"""
    <div class="max-w-7xl mx-auto pb-20 pt-4">
      <div class="flex items-center gap-4 mb-8 border-b border-base-200 pb-6">
        <.link
          navigate={~p"/studio/library"}
          class="btn btn-ghost btn-sm btn-square rounded-md hover:bg-base-200"
        >
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <div>
          <h1 class="text-2xl font-black font-display tracking-tight">
            {@block.title}
          </h1>
          <div class="text-xs font-bold text-base-content/50 uppercase tracking-widest mt-1">
            {gettext("Block Type:")} {Atom.to_string(@block.type) |> String.replace("_", " ")}
          </div>
        </div>
      </div>

      <div class="flex flex-col lg:flex-row items-start gap-8">
        <div class="flex-1 w-full min-w-0 space-y-6">
          <div class="p-6 bg-base-100 border border-base-200 rounded-sm shadow-sm">
            <div class="flex items-center justify-between mb-6 pb-4 border-b border-base-100">
              <h2 class="text-lg font-bold">{gettext("Content Editor")}</h2>
            </div>
            <div class="relative w-full">
              <.content_block block={@block} mode={@block_mode} active={true} />
              <.block_editor :if={@role in [:owner, :writer]} block={@block} target={nil} />
            </div>
          </div>
        </div>

        <div
          :if={@role in [:owner, :writer]}
          class="w-full lg:w-[400px] shrink-0 bg-base-100 rounded-sm border border-base-300 shadow-sm sticky top-8 flex flex-col overflow-hidden"
        >
          <div class="flex items-center justify-between gap-3 px-6 py-5 border-b border-base-200 bg-base-200/30">
            <div>
              <div class="text-[10px] font-bold text-base-content/50 uppercase tracking-widest mb-0.5">
                {gettext("Inspector")}
              </div>
              <div class="text-sm font-bold">
                {gettext("Template Settings")}
              </div>
            </div>
          </div>

          <div class="p-6 space-y-6">
            <.form for={@form} id="meta-form" phx-change="update_meta" phx-submit="update_meta">
              <div class="space-y-4 mb-6">
                <div class="text-xs font-bold text-base-content/50 uppercase tracking-wider">
                  {gettext("General Settings")}
                </div>

                <.input
                  field={@form[:title]}
                  type="text"
                  label={gettext("Template Title")}
                  phx-debounce="500"
                />

                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-bold text-sm">
                      {gettext("Tags (comma separated)")}
                    </span>
                  </label>
                  <input
                    type="text"
                    name="tags_string"
                    value={@tags_string}
                    class="input input-bordered w-full"
                    phx-debounce="500"
                  />
                </div>
              </div>

              <%= if @block.type in [:quiz_question, :quiz_exam, :code] do %>
                <div class="divider my-4"></div>

                <div class="space-y-4 mb-6">
                  <div class="text-xs font-bold text-base-content/50 uppercase tracking-wider">
                    {gettext("Advanced Settings")}
                  </div>

                  <%= if @block.type == :quiz_question do %>
                    <.input
                      type="select"
                      name="library_block[content][question_type]"
                      value={@block.content["question_type"] || "open"}
                      label={gettext("Question Type")}
                      options={[
                        {"Exact Match", "exact_match"},
                        {"Single Choice", "single"},
                        {"Multiple Choice", "multiple"},
                        {"Open Question", "open"}
                      ]}
                    />

                    <%= if @block.content["question_type"] == "exact_match" do %>
                      <div class="mt-2">
                        <label class="flex items-center gap-2 cursor-pointer">
                          <input
                            type="hidden"
                            name="library_block[content][case_sensitive]"
                            value="false"
                          />
                          <input
                            type="checkbox"
                            name="library_block[content][case_sensitive]"
                            value="true"
                            checked={@block.content["case_sensitive"]}
                            class="checkbox checkbox-sm checkbox-primary rounded-sm"
                          />
                          <span class="label-text font-bold">{gettext("Case Sensitive")}</span>
                        </label>
                      </div>
                    <% end %>

                    <.input
                      type="textarea"
                      name="library_block[content][general_explanation]"
                      value={@block.content["general_explanation"]}
                      label={gettext("General Explanation")}
                      phx-debounce="500"
                      rows="3"
                    />
                  <% end %>

                  <%= if @block.type == :quiz_exam do %>
                    <div class="grid grid-cols-2 gap-4">
                      <.input
                        type="number"
                        name="library_block[content][count]"
                        value={@block.content["count"] || 10}
                        label={gettext("Questions")}
                        min="1"
                      />
                      <.input
                        type="number"
                        name="library_block[content][time_limit]"
                        value={@block.content["time_limit"]}
                        label={gettext("Time (Min)")}
                        placeholder="Opt"
                        min="1"
                      />
                    </div>
                    <.input
                      type="number"
                      name="library_block[content][allowed_blur_attempts]"
                      value={@block.content["allowed_blur_attempts"] || 3}
                      label={gettext("Max Cheats")}
                      min="0"
                    />
                    <.input
                      type="text"
                      name="tags_mandatory"
                      value={Enum.join(@block.content["mandatory_tags"] || [], ", ")}
                      label={gettext("Mandatory Tags")}
                      phx-debounce="500"
                    />
                    <.input
                      type="text"
                      name="tags_include"
                      value={Enum.join(@block.content["include_tags"] || [], ", ")}
                      label={gettext("Include Pool")}
                      phx-debounce="500"
                    />
                    <.input
                      type="text"
                      name="tags_exclude"
                      value={Enum.join(@block.content["exclude_tags"] || [], ", ")}
                      label={gettext("Exclude Pool")}
                      phx-debounce="500"
                    />
                  <% end %>

                  <%= if @block.type == :code do %>
                    <.input
                      type="select"
                      name="library_block[content][language]"
                      value={@block.content["language"] || "python"}
                      label={gettext("Language")}
                      options={[{"Python", "python"}, {"SQL", "sql"}, {"Elixir", "elixir"}]}
                    />
                  <% end %>
                </div>
              <% end %>
            </.form>
          </div>

          <div class="p-6 border-t border-base-200 bg-base-200/20 mt-auto">
            <.link
              navigate={~p"/studio/library"}
              class="btn btn-primary rounded-sm w-full shadow-sm"
            >
              <.icon name="hero-check-circle" class="size-5 mr-2" />
              {gettext("Done & Return")}
            </.link>
          </div>
        </div>
      </div>

      <%= if @show_media_modal and @role in [:owner, :writer] do %>
        <.live_component
          module={AthenaWeb.StudioLive.MediaUploadComponent}
          id="media-uploader"
          show={true}
          block_id={@block.id}
          current_user={@current_user}
          upload_type={@upload_type}
        />
      <% end %>
    </div>
    """
  end

  defp determine_role(block, user) do
    shares = Content.list_block_shares(block)

    cond do
      block.owner_id == user.id -> :owner
      share = Enum.find(shares, &(&1.account_id == user.id)) -> share.role
      block.is_public -> :reader
      true -> :none
    end
  end

  defp can_edit?(socket), do: socket.assigns.role in [:owner, :writer]

  defp normalize_content(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> normalize_content()

  defp normalize_content(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), normalize_content(v)} end)

  defp normalize_content(list) when is_list(list), do: Enum.map(list, &normalize_content/1)
  defp normalize_content(value), do: value

  defp parse_quiz_options(opts, correct_id) do
    opts
    |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
    |> Enum.map(fn {_, v} ->
      is_correct =
        if correct_id, do: v["id"] == correct_id, else: v["is_correct"] in ["true", true]

      %{v | "is_correct" => is_correct}
    end)
  end

  defp apply_quiz_meta_overrides(original, overrides) do
    overrides |> apply_exact_match_default(original) |> apply_single_choice_fix(original)
  end

  defp apply_exact_match_default(overrides, original) do
    if overrides["question_type"] == "exact_match" and original["correct_answer"] in [nil, ""],
      do: Map.put(overrides, "correct_answer", "flag{...}"),
      else: overrides
  end

  defp apply_single_choice_fix(
         %{"question_type" => "single"} = overrides,
         %{"question_type" => "multiple"} = original
       ) do
    {new_opts, _} =
      Enum.map_reduce(original["options"] || [], false, fn opt, found ->
        if opt["is_correct"] in ["true", true] and not found,
          do: {%{opt | "is_correct" => true}, true},
          else: {%{opt | "is_correct" => false}, found}
      end)

    Map.put(overrides, "options", new_opts)
  end

  defp apply_single_choice_fix(overrides, _), do: overrides

  defp apply_exam_meta_overrides(overrides, :quiz_exam, params) do
    overrides
    |> parse_and_put_tags(params, "tags_mandatory", "mandatory_tags")
    |> parse_and_put_tags(params, "tags_include", "include_tags")
    |> parse_and_put_tags(params, "tags_exclude", "exclude_tags")
  end

  defp apply_exam_meta_overrides(overrides, _, _), do: overrides

  defp parse_and_put_tags(overrides, params, param_key, content_key) do
    if Map.has_key?(params, param_key),
      do: Map.put(overrides, content_key, parse_tags(params[param_key])),
      else: overrides
  end

  defp parse_tags(nil), do: []

  defp parse_tags(str),
    do:
      str |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end
