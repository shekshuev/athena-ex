defmodule AthenaWeb.StudioLive.LibraryEditor do
  @moduledoc """
  Standalone editor for Library Blocks.
  Uses a strict two-column card UI, matching GradingDetail.
  Implements strict RBAC, real-time collaboration updates, and full block features.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias Athena.Content.LibraryBlock
  alias Athena.Execution
  alias Athena.Identity
  import AthenaWeb.BlockComponents

  on_mount {AthenaWeb.Hooks.Permission, "library.read"}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    return_to = Map.get(params, "return_to", ~p"/studio/library")

    with {:ok, block} <- Content.get_library_block(id),
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
         page_title:
           if(role in [:owner, :writer],
             do: gettext("Edit Template"),
             else: gettext("View Template")
           ),
         block: block,
         form: form,
         return_to: return_to,
         tags_string: Enum.join(block.tags || [], ", "),
         show_media_modal: false,
         upload_type: nil,
         pending_uploads: %{},
         running_tests: %{}
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Template not found or access denied."))
         |> push_navigate(to: return_to)}
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
         |> push_navigate(to: socket.assigns.return_to)}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This template is no longer available."))
         |> push_navigate(to: socket.assigns.return_to)}
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

        successful_results =
          results
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, map} -> map end)

        case media_type do
          "tiptap_image" ->
            {:noreply, handle_tiptap_image_upload(socket, block.id, successful_results)}

          _ ->
            {:noreply,
             handle_standard_media_upload(
               socket,
               block,
               content_map,
               results,
               successful_results,
               media_type
             )}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({ref, result}, socket) when is_map_key(socket.assigns.running_tests, ref) do
    {_block_id, updated_tests} = Map.pop(socket.assigns.running_tests, ref)
    Process.demonitor(ref, [:flush])

    socket =
      if result.status == :accepted do
        put_flash(
          socket,
          :info,
          gettext("Success! Block tests passed (Score: %{score})", score: result.score)
        )
      else
        put_flash(
          socket,
          :error,
          gettext("Test Failed! Status: %{status}.", status: result.status)
        )
      end

    {:noreply, assign(socket, :running_tests, updated_tests)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket)
      when is_map_key(socket.assigns.running_tests, ref) do
    {_block_id, updated_tests} = Map.pop(socket.assigns.running_tests, ref)

    {:noreply,
     socket
     |> put_flash(:error, gettext("Test execution failed or runner disconnected."))
     |> assign(:running_tests, updated_tests)}
  end

  @impl true
  def handle_info({ref, _result}, socket) when is_reference(ref), do: {:noreply, socket}

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

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
            :code -> Map.put(content_map, "body", parsed)
            :file_assignment -> Map.put(content_map, "body", parsed)
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
        options = parse_raw_list(Map.get(content_map, "options", []))

        new_option = %{
          "id" => Ecto.UUID.generate(),
          "text" => %{"type" => "doc", "content" => [%{"type" => "paragraph"}]},
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

  def handle_event("add_ticket_slot", _, socket) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        content_map = normalize_content(block.content || %{})
        slots = parse_raw_list(Map.get(content_map, "slots", []))

        new_slot = %{
          "id" => Ecto.UUID.generate(),
          "tags" => []
        }

        new_content = Map.put(content_map, "slots", slots ++ [new_slot])
        update_and_assign(socket, block, %{"content" => new_content})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_ticket_slot", %{"slot_id" => slot_id}, socket) do
    case can_edit?(socket) do
      true ->
        block = socket.assigns.block
        content_map = normalize_content(block.content || %{})
        slots = Map.get(content_map, "slots", []) |> Enum.reject(&(&1["id"] == slot_id))

        update_and_assign(socket, block, %{"content" => Map.put(content_map, "slots", slots)})

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

  def handle_event("media_upload_clipboard_request", params, socket) do
    if can_edit?(socket) do
      %{
        "file_name" => file_name,
        "file_type" => mime_type,
        "temp_id" => temp_id,
        "file_size" => file_size
      } = params

      bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena"
      unique_id = Ecto.UUID.generate()
      clean_name = file_name |> String.replace(~r/[^a-zA-Z0-9_\-\.]/, "_")
      key = "library/#{socket.assigns.current_user.id}/#{unique_id}-#{clean_name}"

      case Athena.Media.generate_upload_url(bucket, key) do
        {:ok, upload_url} ->
          path_segments = String.split(key, "/")
          final_url = ~p"/media/#{path_segments}"

          pending = socket.assigns[:pending_uploads] || %{}

          updated_pending =
            Map.put(pending, temp_id, %{
              bucket: bucket,
              key: key,
              original_name: file_name,
              size: file_size,
              mime_type: mime_type,
              final_url: final_url
            })

          {:noreply,
           socket
           |> assign(:pending_uploads, updated_pending)
           |> push_event("media_upload_presigned", %{
             temp_id: temp_id,
             upload_url: upload_url,
             final_url: final_url
           })}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not generate upload URL"))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("media_upload_clipboard_success", params, socket) do
    %{
      "temp_id" => temp_id,
      "final_url" => final_url
    } = params

    pending = socket.assigns[:pending_uploads] || %{}

    with true <- can_edit?(socket),
         {upload_data, updated_pending} when not is_nil(upload_data) <- Map.pop(pending, temp_id),
         file_attrs = %{
           "bucket" => upload_data.bucket,
           "key" => upload_data.key,
           "original_name" => upload_data.original_name,
           "mime_type" => upload_data.mime_type,
           "size" => upload_data.size,
           "context" => "course_material",
           "owner_id" => socket.assigns.current_user.id
         },
         {:ok, _file} <- Athena.Media.create_file(file_attrs) do
      {:noreply,
       socket
       |> assign(:pending_uploads, updated_pending)
       |> push_event("insert_media", %{
         block_id: socket.assigns.block.id,
         type: "tiptap_image",
         url: final_url,
         temp_id: temp_id
       })}
    else
      false ->
        {:noreply, socket}

      {nil, _} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save media record"))}
    end
  end

  def handle_event("add_test_case", _, socket) do
    if can_edit?(socket) do
      block = socket.assigns.block
      content_map = normalize_content(block.content || %{})
      test_cases = parse_raw_list(Map.get(content_map, "test_cases", []))

      new_tc = %{
        "id" => Ecto.UUID.generate(),
        "input" => "",
        "expected_output" => "",
        "weight" => if(test_cases == [], do: 100, else: 0),
        "is_hidden" => false
      }

      new_content = Map.put(content_map, "test_cases", test_cases ++ [new_tc])
      update_and_assign(socket, block, %{"content" => new_content})
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_test_case", %{"tc_id" => tc_id}, socket) do
    if can_edit?(socket) do
      block = socket.assigns.block
      content_map = normalize_content(block.content || %{})
      test_cases = parse_raw_list(Map.get(content_map, "test_cases", []))

      new_tc_list = Enum.reject(test_cases, fn tc -> Map.get(tc, "id") == tc_id end)
      new_content = Map.put(content_map, "test_cases", new_tc_list)

      update_and_assign(socket, block, %{"content" => new_content})
    else
      {:noreply, socket}
    end
  end

  def handle_event("run_instructor_test", _, socket) do
    if can_edit?(socket) do
      block = socket.assigns.block
      content_map = normalize_content(block.content || %{})
      code = content_map["solution_code"] || ""
      test_cases = content_map["test_cases"] || []

      dispatch_test_run(socket, block, code, test_cases)
    else
      {:noreply, socket}
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

  def handle_event("update_block_meta", %{"block" => block_params} = params, socket) do
    id = block_params["id"]

    if can_edit?(socket) and socket.assigns.block.id == id do
      block = socket.assigns.block
      content_map = normalize_content(block.content || %{})
      content_overrides = Map.get(block_params, "content", %{})

      content_overrides =
        content_map
        |> apply_quiz_meta_overrides(content_overrides)
        |> apply_exam_meta_overrides(block.type, params)

      new_content = Map.merge(content_map, content_overrides)
      final_params = Map.put(block_params, "content", new_content)

      update_and_assign(socket, block, final_params)
    else
      {:noreply, socket}
    end
  end

  defp dispatch_test_run(socket, _block, "", _test_cases) do
    {:noreply, put_flash(socket, :error, gettext("Please write a Reference Solution first!"))}
  end

  defp dispatch_test_run(socket, _block, _code, []) do
    {:noreply, put_flash(socket, :warning, gettext("Add at least one Test Case before testing."))}
  end

  defp dispatch_test_run(socket, block, code, _test_cases) do
    challenge =
      Ecto.Changeset.apply_changes(
        Athena.Content.CodeChallenge.changeset(
          %Athena.Content.CodeChallenge{},
          block.content
        )
      )

    runner = {:via, :global, :code_runner}

    if :global.whereis_name(:code_runner) != :undefined do
      task =
        Task.Supervisor.async(runner, fn ->
          box_id = System.unique_integer([:positive, :monotonic]) |> rem(10_000)
          Execution.verify(code, challenge, box_id)
        end)

      updated_tests = Map.put(socket.assigns.running_tests, task.ref, block.id)

      {:noreply,
       socket
       |> assign(:running_tests, updated_tests)
       |> put_flash(:info, gettext("Testing reference solution... Please wait."))}
    else
      {:noreply, put_flash(socket, :error, gettext("Runner node is not connected!"))}
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

  defp handle_tiptap_image_upload(socket, block_id, successful_results) do
    socket = assign(socket, show_media_modal: false, upload_type: nil)

    case List.first(successful_results) do
      nil ->
        put_flash(socket, :error, gettext("Failed to upload image"))

      file_map ->
        socket
        |> push_event("insert_media", %{
          block_id: block_id,
          url: file_map["url"],
          type: "tiptap_image"
        })
        |> put_flash(:info, gettext("Image inserted into text!"))
    end
  end

  defp handle_standard_media_upload(
         socket,
         block,
         content_map,
         results,
         successful_results,
         media_type
       ) do
    new_content =
      case media_type do
        "attachment" ->
          Map.put(content_map, "files", Map.get(content_map, "files", []) ++ successful_results)

        _ ->
          case List.first(successful_results) do
            nil -> content_map
            file_map -> Map.put(content_map, "url", file_map["url"])
          end
      end

    error_count = length(results) - length(successful_results)

    socket =
      socket
      |> assign(show_media_modal: false, upload_type: nil)

    socket =
      if error_count > 0 do
        put_flash(socket, :error, gettext("Failed to save %{count} file(s)", count: error_count))
      else
        socket
      end

    update_and_assign(socket, block, %{"content" => new_content})
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        block_mode: if(assigns.role in [:owner, :writer], do: :edit, else: :preview)
      )

    ~H"""
    <div class="max-w-7xl mx-auto pb-20 pt-4">
      <div class="flex items-center gap-4 mb-8 border-b border-base-300 pb-6">
        <.link
          navigate={@return_to}
          class="btn btn-ghost btn-sm btn-square rounded-sm hover:bg-base-200"
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
        <div class="flex-1 w-full min-w-0 lg:min-w-125 space-y-6">
          <div class="p-6 bg-base-100 border border-base-300 rounded-sm">
            <div class="flex items-center justify-between mb-6 pb-4 border-b border-base-300">
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
          class="w-full lg:w-80 xl:w-100 shrink-0 bg-base-100 rounded-sm border border-base-300 xl:sticky xl:top-8 flex flex-col overflow-hidden"
        >
          <div class="flex items-center justify-between gap-3 px-6 py-5 border-b border-base-300">
            <div>
              <div class="text-[10px] font-bold text-base-content/50 uppercase tracking-widest mb-0.5">
                {gettext("Inspector")}
              </div>
              <div class="text-sm font-bold capitalize">
                <%= if @block.type == :quiz_exam do %>
                  {gettext("Assessment Session")}
                <% else %>
                  {Atom.to_string(@block.type) |> String.replace("_", " ")} {gettext("Template")}
                <% end %>
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

                <fieldset class="fieldset">
                  <label class="label">
                    <span class="label-text font-bold text-sm">
                      {gettext("Tags (comma separated)")}
                    </span>
                  </label>
                  <input
                    type="text"
                    name="tags_string"
                    value={@tags_string}
                    class="input w-full"
                    phx-debounce="500"
                  />
                </fieldset>
              </div>

              <%= if @block.type in [:quiz_question, :quiz_exam, :ticket_exam, :code, :file_assignment, :image, :video] do %>
                <div class="divider my-4"></div>

                <div class="space-y-4 mb-6">
                  <div class="text-xs font-bold text-base-content/50 uppercase tracking-wider">
                    {gettext("Advanced Settings")}
                  </div>

                  <%= if @block.type == :quiz_question do %>
                    <div class="mt-4">
                      <.input
                        type="number"
                        name="library_block[content][max_attempts]"
                        value={@block.content["max_attempts"]}
                        label={gettext("Max Attempts")}
                        placeholder={gettext("Leave empty for unlimited")}
                        min="1"
                        phx-debounce="500"
                      />
                    </div>

                    <.input
                      type="select"
                      name="library_block[content][question_type]"
                      value={@block.content["question_type"] || "open"}
                      label={gettext("Question Type")}
                      options={[
                        {gettext("Exact Match (CTF / Text)"), "exact_match"},
                        {gettext("Single Choice (Radio)"), "single"},
                        {gettext("Multiple Choice (Checkbox)"), "multiple"},
                        {gettext("Open Question (Essay)"), "open"}
                      ]}
                    />

                    <.input
                      type="select"
                      name="library_block[content][answer_type]"
                      value={@block.content["answer_type"] || "plain_text"}
                      label={gettext("Answer Input Type")}
                      options={[
                        {gettext("Plain Text"), "plain_text"},
                        {gettext("Rich Text"), "rich_text"}
                      ]}
                      phx-debounce="300"
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
                            class="checkbox checkbox-sm checkbox-primary mt-0.5"
                          />
                          <span class="label-text font-bold">{gettext("Case Sensitive")}</span>
                        </label>
                      </div>
                    <% end %>

                    <div class="mt-4">
                      <.input
                        type="textarea"
                        name="library_block[content][general_explanation]"
                        value={@block.content["general_explanation"]}
                        label={gettext("General Explanation (shown after submission)")}
                        phx-debounce="500"
                        rows="3"
                      />
                    </div>
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

                  <%= if @block.type == :ticket_exam do %>
                    <div class="flex flex-col gap-3">
                      <.input
                        type="number"
                        name="library_block[content][time_limit]"
                        value={@block.content["time_limit"]}
                        label={gettext("Time Limit (sec)")}
                        placeholder={gettext("Optional")}
                        min="1"
                        phx-debounce="500"
                      />
                    </div>

                    <div class="flex items-center justify-between mb-2 mt-6">
                      <label class="label p-0">
                        <span class="label-text font-bold text-xs uppercase text-base-content/70">
                          {gettext("Ticket Slots")}
                        </span>
                      </label>
                      <button
                        type="button"
                        phx-click="add_ticket_slot"
                        class="btn btn-xs btn-ghost text-primary"
                      >
                        <.icon name="hero-plus" class="size-3 mr-1" /> {gettext("Add Slot")}
                      </button>
                    </div>

                    <div class="space-y-3">
                      <% slots = @block.content["slots"] || [] %>
                      <%= for {slot, index} <- Enum.with_index(slots) do %>
                        <div class="flex items-center gap-2">
                          <input
                            type="hidden"
                            name={"library_block[content][slots][#{index}][id]"}
                            value={slot["id"]}
                          />
                          <div class="flex-1">
                            <.input
                              type="text"
                              name={"library_block[content][slots][#{index}][tags_string]"}
                              value={Enum.join(slot["tags"] || [], ", ")}
                              placeholder={gettext("e.g. db, theory")}
                              phx-debounce="500"
                            />
                          </div>
                          <button
                            type="button"
                            phx-click="remove_ticket_slot"
                            phx-value-slot_id={slot["id"]}
                            class="btn btn-ghost btn-sm btn-square text-error"
                            title={gettext("Remove Slot")}
                          >
                            <.icon name="hero-x-mark" class="size-4" />
                          </button>
                        </div>
                      <% end %>
                      <div :if={slots == []} class="text-sm italic opacity-50 pb-2">
                        {gettext("No slots added. Add slots to specify question tags.")}
                      </div>
                    </div>
                  <% end %>

                  <%= if @block.type == :code do %>
                    <.input
                      type="select"
                      name="library_block[content][language]"
                      value={@block.content["language"] || Execution.default_language()}
                      label={gettext("Language")}
                      options={Execution.options()}
                    />
                    <div class="grid grid-cols-2 gap-3">
                      <.input
                        type="number"
                        name="library_block[content][time_limit]"
                        value={@block.content["time_limit"] || 1.0}
                        label={gettext("Time Limit (s)")}
                        step="0.1"
                        min="0.1"
                        max="15.0"
                        phx-debounce="500"
                      />
                      <.input
                        type="number"
                        name="library_block[content][memory_limit]"
                        value={@block.content["memory_limit"] || 65_536}
                        label={gettext("Memory (KB)")}
                        step="1024"
                        min="16384"
                        max="524288"
                        phx-debounce="500"
                      />
                    </div>
                    <div class="mt-2">
                      <.input
                        type="number"
                        name="library_block[content][max_attempts]"
                        value={@block.content["max_attempts"]}
                        label={gettext("Max Attempts")}
                        placeholder={gettext("Leave empty for unlimited")}
                        min="1"
                        phx-debounce="500"
                      />
                    </div>
                  <% end %>

                  <%= if @block.type == :file_assignment do %>
                    <.input
                      type="number"
                      name="library_block[content][max_files]"
                      value={@block.content["max_files"] || 1}
                      label={gettext("Max Files Allowed")}
                      min="1"
                      max="20"
                      step="1"
                      phx-debounce="500"
                    />
                    <div class="text-xs text-base-content/50 leading-relaxed -mt-2">
                      {gettext("Students upload files for manual review. Allowed range: 1–20 files.")}
                    </div>
                  <% end %>

                  <%= if @block.type in [:image, :video] do %>
                    <.button
                      type="button"
                      phx-click="request_media_upload"
                      phx-value-media_type={@block.type}
                      class="btn btn-outline w-full mb-2"
                    >
                      <.icon name="hero-cloud-arrow-up" class="size-4" /> {if @block.content["url"],
                        do: gettext("Replace File"),
                        else: gettext("Upload File")}
                    </.button>
                    <%= if @block.type == :image do %>
                      <.input
                        type="text"
                        name="library_block[content][alt]"
                        value={@block.content["alt"]}
                        label={gettext("Alt Text")}
                        phx-debounce="500"
                      />
                    <% end %>
                    <%= if @block.type == :video do %>
                      <.input
                        type="text"
                        name="library_block[content][poster_url]"
                        value={@block.content["poster_url"]}
                        label={gettext("Poster URL")}
                        phx-debounce="500"
                      />
                    <% end %>
                  <% end %>
                </div>
              <% end %>
            </.form>
          </div>

          <div class="p-6 border-t border-base-300 mt-auto">
            <.link
              navigate={@return_to}
              class="btn btn-primary rounded-sm w-full"
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
          context="library"
        />
      <% end %>
    </div>
    """
  end

  defp determine_role(block, user) do
    shares = Content.list_block_shares(block)

    is_pinned_to_course? = Content.pinned_to_any_course?(block.id)

    cond do
      block.owner_id == user.id -> :owner
      share = Enum.find(shares, &(&1.account_id == user.id)) -> share.role
      Identity.can?(user, "library.update", block) -> :writer
      block.is_public -> :reader
      is_pinned_to_course? -> :reader
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
        if correct_id do
          v["id"] == correct_id
        else
          v["is_correct"] in ["true", true]
        end

      text_map =
        case Jason.decode(v["text"]) do
          {:ok, decoded} ->
            decoded

          _ ->
            %{
              "type" => "doc",
              "content" => [
                %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => v["text"]}]}
              ]
            }
        end

      %{v | "is_correct" => is_correct, "text" => text_map}
    end)
  end

  defp apply_quiz_meta_overrides(original_content, overrides) do
    overrides
    |> apply_exact_match_default(original_content)
    |> apply_single_choice_fix(original_content)
    |> apply_case_sensitive_fix()
  end

  defp apply_case_sensitive_fix(overrides) do
    if Map.has_key?(overrides, "case_sensitive") do
      Map.put(overrides, "case_sensitive", overrides["case_sensitive"] in ["true", true])
    else
      overrides
    end
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

  defp apply_exam_meta_overrides(overrides, :ticket_exam, block_params) do
    content_params =
      get_in(block_params, ["library_block", "content"]) ||
        get_in(block_params, ["block", "content"]) ||
        %{}

    case Map.fetch(content_params, "slots") do
      {:ok, raw_slots} -> Map.put(overrides, "slots", parse_raw_slots(raw_slots))
      :error -> overrides
    end
  end

  defp apply_exam_meta_overrides(overrides, _, _), do: overrides

  defp parse_raw_slots(raw_slots) when is_map(raw_slots) and not is_struct(raw_slots) do
    raw_slots
    |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
    |> Enum.map(fn {_, v} ->
      %{
        "id" => v["id"],
        "tags" => parse_tags(v["tags_string"])
      }
    end)
  end

  defp parse_raw_slots(raw_slots) when is_list(raw_slots), do: raw_slots
  defp parse_raw_slots(_), do: []

  defp parse_and_put_tags(overrides, params, param_key, content_key) do
    if Map.has_key?(params, param_key),
      do: Map.put(overrides, content_key, parse_tags(params[param_key])),
      else: overrides
  end

  defp parse_tags(nil), do: []

  defp parse_tags(str),
    do:
      str |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp parse_raw_list(raw) when is_map(raw) do
    raw
    |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
    |> Enum.map(fn {_, v} -> v end)
  end

  defp parse_raw_list(raw) when is_list(raw), do: raw
  defp parse_raw_list(_), do: []
end
