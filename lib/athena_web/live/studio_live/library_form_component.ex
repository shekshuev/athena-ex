defmodule AthenaWeb.StudioLive.LibraryFormComponent do
  @moduledoc """
  A LiveComponent for creating and editing library block metadata.

  Handles the parsing of comma-separated tags from the UI into the 
  `{:array, :string}` format required by the database.
  """
  use AthenaWeb, :live_component

  alias Athena.Content
  alias Athena.Content.LibraryBlock

  @doc """
  Initializes the component state.
  Converts the array of tags into a comma-separated string for the HTML input.
  """
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{library_block: block} = assigns, socket) do
    changeset = LibraryBlock.changeset(block, %{})

    tags_string = Enum.join(block.tags || [], ", ")

    type_options = [
      {gettext("Text"), :text},
      {gettext("Code"), :code},
      {gettext("Quiz Question"), :quiz_question}
    ]

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, to_form(changeset))
     |> assign(:tags_string, tags_string)
     |> assign(:type_options, type_options)}
  end

  @doc """
  Handles UI validation events.
  """
  @impl true
  def handle_event("validate", %{"library_block" => params} = form_data, socket) do
    params = put_tags_array(params, form_data["tags_string"])

    changeset =
      socket.assigns.library_block
      |> LibraryBlock.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), tags_string: form_data["tags_string"])}
  end

  def handle_event("save", %{"library_block" => params} = form_data, socket) do
    params = put_tags_array(params, form_data["tags_string"])

    params =
      if socket.assigns.action == :new do
        params
        |> Map.put("owner_id", socket.assigns.current_user.id)
        # Default empty JSON for new blocks
        |> Map.put_new("content", %{})
      else
        params
      end

    save_block(socket, socket.assigns.action, params)
  end

  defp save_block(socket, :edit, params) do
    case Content.update_library_block(socket.assigns.library_block, params) do
      {:ok, block} ->
        notify_parent({:saved, block})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Template updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_block(socket, :new, params) do
    case Content.create_library_block(params) do
      {:ok, block} ->
        notify_parent({:saved, block})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Template created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp put_tags_array(params, tags_string) do
    tags =
      (tags_string || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(params, "tags", tags)
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.form
        for={@form}
        id="library-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col h-full"
      >
        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div class="divider text-xs font-bold uppercase text-base-content/50">
            {gettext("Template Metadata")}
          </div>

          <.input
            field={@form[:title]}
            type="text"
            label={gettext("Title")}
            placeholder={gettext("e.g. Standard Python Quiz")}
            required
          />

          <.input
            field={@form[:type]}
            type="select"
            label={gettext("Block Type")}
            options={@type_options}
            disabled={@action == :edit}
            required
          />

          <div class="form-control mb-2 w-full">
            <label for="tags_string" class="label">
              <span class="label-text font-bold">{gettext("Tags (comma separated)")}</span>
            </label>
            <input
              type="text"
              name="tags_string"
              id="tags_string"
              value={@tags_string}
              class="input input-bordered w-full"
              placeholder={gettext("elixir, hard, quiz")}
            />
            <p class="mt-1 text-xs opacity-60">
              {gettext("Used for filtering and dynamic quiz generation.")}
            </p>
          </div>
        </div>

        <div class="shrink-0 p-6 border-t border-base-200 bg-base-100 flex justify-end gap-3">
          <.link patch={@patch} class="btn btn-ghost">{gettext("Cancel")}</.link>
          <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
