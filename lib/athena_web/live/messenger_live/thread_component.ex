defmodule AthenaWeb.MessengerLive.ThreadComponent do
  @moduledoc """
  Right-hand pane: the message list for the active conversation (with a
  "load earlier" cursor), its header (title + online/typing status), and
  the message composer. Also owns editing/deleting one's own messages.
  """
  use AthenaWeb, :live_component

  alias Athena.Identity
  alias Athena.Messaging
  import AthenaWeb.MessengerLive.MessageComponent, only: [message_bubble: 1]

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:has_more, fn -> true end)}
  end

  @impl true
  def handle_event("save_edit", %{"id" => id, "body" => body}, socket) do
    case fetch_message(socket, id) do
      {:ok, message} ->
        case Messaging.edit_message(socket.assigns.current_user, message, %{"body" => body}) do
          {:ok, _updated} ->
            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not save the edit."))}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_message", %{"id" => id}, socket) do
    case fetch_message(socket, id) do
      {:ok, message} ->
        Messaging.delete_message(socket.assigns.current_user, message)
        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, socket}
  end

  defp fetch_message(socket, message_id) do
    with {:ok, message} <- Messaging.get_message(message_id),
         true <- message.conversation_id == socket.assigns.conversation.id do
      {:ok, message}
    else
      _ -> :error
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full" id={@id}>
      <div class="h-16 flex items-center gap-3 px-4 border-b border-base-300 shrink-0">
        <.button navigate={~p"/messenger"} variant="ghost" size="sm" class="btn-square sm:hidden">
          <.icon name="hero-arrow-left" class="size-5" />
        </.button>

        <.avatar
          initials={String.slice(header_title(@conversation), 0..1)}
          size="w-9"
          text_size="text-xs"
          color={if @conversation.kind == :cohort, do: "secondary", else: "neutral"}
        />

        <div class="min-w-0">
          <div class="font-bold truncate">{header_title(@conversation)}</div>
          <div class="text-xs text-base-content/50 truncate">{header_subtitle(assigns)}</div>
        </div>
      </div>

      <div
        class="flex-1 overflow-y-auto px-4 py-3 space-y-2"
        id={"messages-#{@conversation.id}"}
        phx-update="stream"
      >
        <div :for={{dom_id, message} <- @messages} id={dom_id} class="py-0.5">
          <.message_bubble
            message={message}
            own={message.account_id == @current_user.id}
            myself={@myself}
          />
        </div>
      </div>

      <div class="border-t border-base-300 p-3 shrink-0">
        <.live_component
          module={AthenaWeb.MessengerLive.ComposerComponent}
          id={"composer-#{@conversation.id}"}
          conversation={@conversation}
          current_user={@current_user}
        />
      </div>
    </div>
    """
  end

  defp header_title(%{kind: :direct, other_participant: nil}), do: gettext("Unknown user")

  defp header_title(%{kind: :direct, other_participant: account}),
    do: Identity.display_name(account)

  defp header_title(%{kind: :cohort, cohort: nil}), do: gettext("Cohort chat")
  defp header_title(%{kind: :cohort, cohort: cohort}), do: cohort.name

  defp header_subtitle(%{conversation: %{kind: :direct, other_participant: account}} = assigns) do
    cond do
      typing?(assigns) ->
        gettext("typing…")

      account && MapSet.member?(assigns.online_account_ids, account.id) ->
        gettext("Online")

      account && account.last_seen_at ->
        gettext("Last seen %{time}", time: relative_time(account.last_seen_at))

      true ->
        gettext("Offline")
    end
  end

  defp header_subtitle(%{conversation: %{kind: :cohort}} = assigns) do
    if typing?(assigns), do: gettext("typing…"), else: gettext("Group chat")
  end

  defp typing?(%{typing_accounts: typing_accounts}), do: map_size(typing_accounts) > 0

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{n}m ago", n: div(diff, 60))
      diff < 86_400 -> gettext("%{n}h ago", n: div(diff, 3600))
      true -> Calendar.strftime(datetime, "%d.%m.%Y")
    end
  end
end
