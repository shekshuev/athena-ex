defmodule AthenaWeb.MessengerLive.Index do
  @moduledoc """
  Two-pane messenger: a left-hand list of direct and cohort conversations,
  and the active thread (or the "new conversation" search) on the right.
  """
  use AthenaWeb, :live_view

  alias Athena.Identity
  alias Athena.Messaging

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:conversation, nil)
      |> assign(:subscribed_conversation_id, nil)
      |> assign(:typing_accounts, %{})
      |> assign(:online_account_ids, online_account_ids())
      |> load_conversations()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> load_conversations()
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> unsubscribe_conversation()
    |> assign(:conversation, nil)
    |> assign(:page_title, gettext("Messenger"))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> unsubscribe_conversation()
    |> assign(:conversation, nil)
    |> assign(:page_title, gettext("New Message"))
  end

  defp apply_action(socket, :show, %{"conversation_id" => id}) do
    user = socket.assigns.current_user

    case Messaging.get_conversation(user, id) do
      {:ok, conversation} ->
        # Captured *before* anything marks the conversation read, so the
        # "new messages" divider reflects where the user's read cursor was
        # when they opened it, not the position it's about to move to.
        last_read_at = Messaging.get_last_read_at(user, conversation)
        messages = Messaging.list_messages(conversation)
        has_unread = conversation.unread_count > 0

        socket
        |> unsubscribe_conversation()
        |> subscribe_conversation(conversation.id)
        |> assign(:conversation, conversation)
        |> assign(:typing_accounts, %{})
        |> assign(:page_title, conversation_title(conversation))
        |> stream(:messages, divider_items(messages, last_read_at, has_unread), reset: true)
        |> push_event("scroll_thread", %{to: if(has_unread, do: "read-divider", else: "bottom")})

      {:error, :not_found} ->
        socket
        |> put_flash(:error, gettext("Conversation not found."))
        |> push_navigate(to: ~p"/messenger")
    end
  end

  # Inserts a synthetic `%{id: "read-divider", kind: :divider}` marker
  # right before the first message the user hasn't seen yet, so the stream
  # (and `ThreadComponent`'s template) can render a "new messages" line
  # there. Plain map, not a `Message` struct, deliberately — it flows
  # through the same stream as real messages (Phoenix.LiveView.LiveStream
  # only needs an `:id`), and `divider?/1` tells them apart.
  defp divider_items(messages, _last_read_at, false), do: messages

  defp divider_items(messages, last_read_at, true) do
    index =
      Enum.find_index(messages, fn m ->
        is_nil(last_read_at) or DateTime.compare(m.inserted_at, last_read_at) == :gt
      end)

    case index do
      nil -> messages
      idx -> List.insert_at(messages, idx, %{id: "read-divider", kind: :divider})
    end
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/messenger/#{id}")}
  end

  def handle_event("new_conversation", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/messenger/new")}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, maybe_append_message(socket, message)}
  end

  def handle_info({:message_updated, message}, socket) do
    {:noreply, maybe_update_message(socket, message)}
  end

  def handle_info({:typing, account_id}, socket) do
    current_user_id = socket.assigns.current_user.id

    case account_id do
      ^current_user_id ->
        {:noreply, socket}

      _ ->
        Process.send_after(self(), {:clear_typing, account_id}, 4000)
        {:noreply, update(socket, :typing_accounts, &Map.put(&1, account_id, true))}
    end
  end

  def handle_info({:clear_typing, account_id}, socket) do
    {:noreply, update(socket, :typing_accounts, &Map.delete(&1, account_id))}
  end

  def handle_info({:conversation_participants_changed, conversation_id}, socket) do
    {:noreply,
     socket |> load_conversations() |> maybe_evict_current_conversation(conversation_id)}
  end

  def handle_info({:inbox_updated, _conversation_id}, socket) do
    {:noreply, load_conversations(socket)}
  end

  def handle_info({AthenaWeb.MessengerLive.NewDmComponent, {:started, conversation}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/messenger/#{conversation.id}")}
  end

  def handle_info(%{event: "presence_diff", payload: payload}, socket) do
    {:noreply, apply_presence_diff(socket, payload)}
  end

  def handle_info({:went_offline, account_id}, socket) do
    {:noreply, maybe_refresh_other_participant(socket, account_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp apply_presence_diff(socket, %{joins: joins, leaves: leaves}) do
    online =
      socket.assigns.online_account_ids
      |> MapSet.union(MapSet.new(Map.keys(joins)))
      |> MapSet.difference(MapSet.new(Map.keys(leaves)))

    assign(socket, :online_account_ids, online)
  end

  defp maybe_refresh_other_participant(socket, account_id) do
    case socket.assigns.conversation do
      %{kind: :direct, other_participant: %{id: ^account_id}} = conversation ->
        refreshed = Identity.get_accounts_map([account_id]) |> Map.get(account_id)
        assign(socket, :conversation, %{conversation | other_participant: refreshed})

      _ ->
        socket
    end
  end

  defp online_account_ids do
    "presence:lobby" |> AthenaWeb.Presence.list() |> Map.keys() |> MapSet.new()
  end

  defp maybe_append_message(socket, message) do
    if current_conversation?(socket, message.conversation_id) do
      Messaging.mark_read(socket.assigns.current_user, socket.assigns.conversation)

      socket
      |> stream_insert(:messages, message)
      |> push_event("scroll_thread", %{to: "bottom"})
    else
      socket
    end
  end

  defp maybe_update_message(socket, message) do
    if current_conversation?(socket, message.conversation_id) do
      stream_insert(socket, :messages, message)
    else
      socket
    end
  end

  defp maybe_evict_current_conversation(socket, conversation_id) do
    case socket.assigns.conversation do
      %{id: ^conversation_id} = conversation ->
        case Messaging.get_conversation(socket.assigns.current_user, conversation.id) do
          {:ok, refreshed} ->
            assign(socket, :conversation, refreshed)

          {:error, :not_found} ->
            socket
            |> put_flash(:info, gettext("You left this conversation."))
            |> push_navigate(to: ~p"/messenger")
        end

      _ ->
        socket
    end
  end

  defp current_conversation?(%{assigns: %{conversation: %{id: id}}}, id), do: true
  defp current_conversation?(_socket, _conversation_id), do: false

  defp subscribe_conversation(socket, id) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Athena.PubSub, "conversation:#{id}")
    assign(socket, :subscribed_conversation_id, id)
  end

  defp unsubscribe_conversation(socket) do
    case socket.assigns[:subscribed_conversation_id] do
      nil ->
        socket

      id ->
        if connected?(socket), do: Phoenix.PubSub.unsubscribe(Athena.PubSub, "conversation:#{id}")
        mark_current_conversation_read(socket)
        assign(socket, :subscribed_conversation_id, nil)
    end
  end

  # Marking read happens when *leaving* a conversation (here, and in
  # `terminate/2` for a closed tab/navigated-away socket) rather than the
  # instant it's opened — that's what leaves a window, however brief, for
  # the "new messages" divider built in `apply_action/3` to actually mean
  # something.
  defp mark_current_conversation_read(socket) do
    if conversation = socket.assigns[:conversation] do
      Messaging.mark_read(socket.assigns.current_user, conversation)
    end
  end

  @impl true
  def terminate(_reason, socket) do
    mark_current_conversation_read(socket)
    :ok
  end

  defp load_conversations(socket) do
    conversations = Messaging.list_conversations(socket.assigns.current_user)
    {direct, cohort} = Enum.split_with(conversations, &(&1.kind == :direct))

    socket
    |> stream(:direct_conversations, direct, reset: true)
    |> stream(:cohort_conversations, cohort, reset: true)
    |> assign(:has_conversations, conversations != [])
    |> assign(:has_cohort_conversations, cohort != [])
  end

  defp conversation_title(%{kind: :direct, other_participant: nil}), do: gettext("Direct message")

  defp conversation_title(%{kind: :direct, other_participant: account}),
    do: Identity.display_name(account)

  defp conversation_title(%{kind: :cohort, cohort: nil}), do: gettext("Cohort chat")
  defp conversation_title(%{kind: :cohort, cohort: cohort}), do: cohort.name

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh-4rem)] -m-4 sm:-m-6 lg:-m-8 border-t border-base-300">
      <div class="w-full sm:w-80 shrink-0 border-r border-base-300 flex flex-col bg-base-100">
        <.live_component
          module={AthenaWeb.MessengerLive.ConversationListComponent}
          id="conversation-list"
          direct_conversations={@streams.direct_conversations}
          cohort_conversations={@streams.cohort_conversations}
          has_conversations={@has_conversations}
          has_cohort_conversations={@has_cohort_conversations}
          current_conversation_id={@conversation && @conversation.id}
          current_user={@current_user}
        />
      </div>

      <div class={[
        "flex-1 min-w-0 flex-col bg-base-200/30",
        if(@live_action == :index, do: "hidden sm:flex", else: "flex")
      ]}>
        <.live_component
          :if={@live_action == :new}
          module={AthenaWeb.MessengerLive.NewDmComponent}
          id="new-dm"
          current_user={@current_user}
        />

        <.live_component
          :if={@live_action == :show && @conversation}
          module={AthenaWeb.MessengerLive.ThreadComponent}
          id={"thread-#{@conversation.id}"}
          conversation={@conversation}
          current_user={@current_user}
          messages={@streams.messages}
          typing_accounts={@typing_accounts}
          online_account_ids={@online_account_ids}
        />

        <.empty_state
          :if={@live_action == :index}
          icon="hero-chat-bubble-left-right"
          title={gettext("Select a conversation")}
          description={gettext("Choose a conversation from the list, or start a new one.")}
          class="m-auto"
        >
          <.button variant="primary" class="mt-4" phx-click="new_conversation">
            <.icon name="hero-pencil-square" class="size-4" />
            {gettext("New Message")}
          </.button>
        </.empty_state>
      </div>
    </div>
    """
  end
end
