defmodule AthenaWeb.MessengerLive.ConversationListComponent do
  @moduledoc """
  Left-hand pane of the messenger: a live-streamed list of the current
  user's conversations, grouped into direct messages and cohort chats.

  Click events (`select_conversation`, `new_conversation`) are intentionally
  left untargeted so they bubble up to the parent `MessengerLive.Index`,
  which owns navigation and subscriptions.
  """
  use AthenaWeb, :live_component

  alias Athena.Identity

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full" id={@id}>
      <div class="h-16 flex items-center justify-between px-4 border-b border-base-300 shrink-0">
        <h1 class="text-lg font-display font-bold">{gettext("Messenger")}</h1>
        <.icon_button
          icon="hero-pencil-square"
          label={gettext("New Message")}
          variant="primary"
          phx-click="new_conversation"
        />
      </div>

      <div class="flex-1 overflow-y-auto">
        <.empty_state
          :if={!@has_conversations}
          icon="hero-chat-bubble-left-right"
          title={gettext("No conversations yet")}
          description={gettext("Start a new conversation to message someone.")}
          class="py-12"
        />

        <div :if={@has_conversations}>
          <div id="direct-conversations" phx-update="stream">
            <div :for={{dom_id, conversation} <- @direct_conversations} id={dom_id}>
              <.conversation_row
                conversation={conversation}
                title={other_participant_name(conversation)}
                active={conversation.id == @current_conversation_id}
                current_user={@current_user}
              />
            </div>
          </div>

          <div
            :if={@has_cohort_conversations}
            class="px-4 pt-4 pb-1 text-[10px] font-black text-base-content/50 uppercase tracking-widest"
          >
            {gettext("Cohort Chats")}
          </div>

          <div id="cohort-conversations" phx-update="stream">
            <div :for={{dom_id, conversation} <- @cohort_conversations} id={dom_id}>
              <.conversation_row
                conversation={conversation}
                title={cohort_name(conversation)}
                subtitle={gettext("Group chat")}
                active={conversation.id == @current_conversation_id}
                current_user={@current_user}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :conversation, :map, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :active, :boolean, default: false
  attr :current_user, :map, required: true

  defp conversation_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_conversation"
      phx-value-id={@conversation.id}
      class={[
        "w-full flex items-center gap-3 px-4 py-3 text-left border-b border-base-200 hover:bg-base-200/60 transition-colors",
        @active && "bg-primary/10"
      ]}
    >
      <div class="avatar placeholder shrink-0">
        <div class={[
          "rounded-full w-10",
          @conversation.kind == :cohort && "bg-secondary text-secondary-content",
          @conversation.kind == :direct && "bg-neutral text-neutral-content"
        ]}>
          <span class="text-sm uppercase">{String.slice(@title, 0..1)}</span>
        </div>
      </div>

      <div class="min-w-0 flex-1">
        <div class="flex items-center justify-between gap-2">
          <span class="font-bold truncate">{@title}</span>
          <span :if={last_message_at(@conversation)} class="text-xs text-base-content/50 shrink-0">
            {format_time(last_message_at(@conversation))}
          </span>
        </div>
        <div class="flex items-center justify-between gap-2 mt-0.5">
          <span class="text-sm text-base-content/60 truncate">
            {preview_text(@conversation, @subtitle)}
          </span>
          <div class="flex items-center gap-1 shrink-0">
            <span :if={@conversation.has_unread_mention} class="badge badge-warning badge-xs">
              @
            </span>
            <span :if={@conversation.unread_count > 0} class="badge badge-primary badge-sm">
              {@conversation.unread_count}
            </span>
          </div>
        </div>
      </div>
    </button>
    """
  end

  defp other_participant_name(%{other_participant: nil}), do: gettext("Unknown user")
  defp other_participant_name(%{other_participant: account}), do: Identity.display_name(account)

  defp cohort_name(%{cohort: nil}), do: gettext("Cohort chat")
  defp cohort_name(%{cohort: cohort}), do: cohort.name

  defp last_message_at(%{last_message: nil}), do: nil
  defp last_message_at(%{last_message: message}), do: message.inserted_at

  defp preview_text(%{last_message: nil}, subtitle), do: subtitle || gettext("No messages yet")

  defp preview_text(%{last_message: %{deleted_at: deleted_at}}, _subtitle)
       when not is_nil(deleted_at),
       do: gettext("Message deleted")

  defp preview_text(%{last_message: message}, _subtitle) do
    sender_prefix =
      if message.account, do: Identity.display_name(message.account) <> ": ", else: ""

    sender_prefix <> String.slice(message.body || "", 0, 60)
  end

  defp format_time(datetime) do
    today = Date.utc_today()
    date = DateTime.to_date(datetime)

    if date == today do
      Calendar.strftime(datetime, "%H:%M")
    else
      Calendar.strftime(datetime, "%d.%m")
    end
  end
end
