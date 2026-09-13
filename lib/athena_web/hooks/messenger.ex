defmodule AthenaWeb.Hooks.Messenger do
  @moduledoc """
  LiveView hook that makes the unread-conversations badge (`@unread_conversations_count`)
  available on every authenticated page, and keeps it live by subscribing to
  the current user's inbox topic.
  """
  import Phoenix.LiveView
  import Phoenix.Component
  alias Athena.Messaging

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:cont, assign(socket, :unread_conversations_count, 0)}

      user ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Athena.PubSub, "inbox:#{user.id}")
          Phoenix.PubSub.subscribe(Athena.PubSub, "presence:lobby")
          AthenaWeb.Presence.track(self(), "presence:lobby", user.id, %{})
        end

        socket =
          socket
          |> assign(:unread_conversations_count, Messaging.count_unread_conversations(user))
          |> attach_hook(:messenger_inbox, :handle_info, &handle_inbox_event/2)

        {:cont, socket}
    end
  end

  # This hook is attached on every authenticated LiveView (for the nav
  # badge), but only `MessengerLive.Index` itself has `handle_info` clauses
  # for `{:inbox_updated, _}`, presence diffs, and `{:went_offline, _}`.
  # Every other page must never see these — otherwise any page mounted
  # while another user connects/disconnects (a constant background event)
  # would crash with a `FunctionClauseError` in its own `handle_info/2`.
  defp handle_inbox_event({:inbox_updated, _conversation_id} = message, socket) do
    count = Messaging.count_unread_conversations(socket.assigns.current_user)
    socket = assign(socket, :unread_conversations_count, count)
    propagate_to_messenger(message, socket)
  end

  defp handle_inbox_event(%{topic: "presence:lobby"} = message, socket) do
    propagate_to_messenger(message, socket)
  end

  defp handle_inbox_event({:went_offline, _account_id} = message, socket) do
    propagate_to_messenger(message, socket)
  end

  # Fully handled here (toast + browser Notification, see app.js) on
  # whatever page the user happens to be on — unlike the events above,
  # nothing needs this forwarded to a LiveView's own `handle_info`.
  # Suppressed when the user is already looking at that exact conversation,
  # since `MessengerLive.Index` already live-appends the message there.
  defp handle_inbox_event({:new_message_notification, notification}, socket) do
    socket =
      if viewing_conversation?(socket, notification.conversation_id) do
        socket
      else
        push_event(socket, "new_message_notification", notification)
      end

    {:halt, socket}
  end

  defp handle_inbox_event(_message, socket), do: {:cont, socket}

  defp propagate_to_messenger(_message, %{view: AthenaWeb.MessengerLive.Index} = socket),
    do: {:cont, socket}

  defp propagate_to_messenger(_message, socket), do: {:halt, socket}

  defp viewing_conversation?(
         %{view: AthenaWeb.MessengerLive.Index, assigns: %{conversation: %{id: id}}},
         id
       ),
       do: true

  defp viewing_conversation?(_socket, _conversation_id), do: false
end
