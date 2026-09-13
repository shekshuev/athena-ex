defmodule AthenaWeb.MessengerLive.ComposerComponent do
  @moduledoc """
  The message input: enforces the character limit (mirrored from
  `Athena.Messaging.Message.max_length/0`), broadcasts a throttled "typing"
  event, offers `@mention` autocomplete in cohort chats, and posts the
  message on submit.

  Mention detection only looks at the end of the current text (no
  caret-position tracking) — an accepted v1 simplification.
  """
  use AthenaWeb, :live_component

  alias Athena.Identity
  alias Athena.Messaging
  alias Athena.Messaging.Message

  @typing_throttle_ms 2000
  @mention_regex ~r/@([\p{L}\p{N}_]*)$/u

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:body, fn -> "" end)
     |> assign_new(:last_typing_broadcast_at, fn -> nil end)
     |> assign_new(:mention_suggestions, fn -> [] end)
     |> assign_new(:selected_mentions, fn -> [] end)
     |> assign_new(:participants, fn -> load_participants(assigns.conversation) end)}
  end

  @impl true
  def handle_event("typing", %{"body" => body}, socket) do
    {:noreply,
     socket
     |> maybe_broadcast_typing()
     |> assign(:body, body)
     |> update_mention_suggestions(body)}
  end

  def handle_event("pick_mention", %{"account_id" => account_id}, socket) do
    case Enum.find(socket.assigns.participants, &(&1.id == account_id)) do
      nil ->
        {:noreply, socket}

      account ->
        name = Identity.display_name(account)
        new_body = Regex.replace(@mention_regex, socket.assigns.body, "@" <> name <> " ")

        {:noreply,
         socket
         |> assign(:body, new_body)
         |> assign(:mention_suggestions, [])
         |> update(:selected_mentions, &[{account_id, "@" <> name} | &1])}
    end
  end

  def handle_event("send", %{"body" => body}, socket) do
    case String.trim(body) do
      "" ->
        {:noreply, socket}

      trimmed ->
        mention_ids =
          socket.assigns.selected_mentions
          |> Enum.filter(fn {_id, text} -> String.contains?(trimmed, text) end)
          |> Enum.map(&elem(&1, 0))

        case Messaging.post_message(socket.assigns.current_user, socket.assigns.conversation, %{
               "body" => trimmed,
               "mention_account_ids" => mention_ids
             }) do
          {:ok, _message} ->
            {:noreply,
             socket
             |> assign(:body, "")
             |> assign(:mention_suggestions, [])
             |> assign(:selected_mentions, [])}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not send the message."))}
        end
    end
  end

  defp load_participants(%{kind: :cohort} = conversation),
    do: Messaging.list_participant_accounts(conversation)

  defp load_participants(_conversation), do: []

  defp update_mention_suggestions(socket, body) do
    if socket.assigns.conversation.kind == :cohort do
      case mention_query(body) do
        nil ->
          assign(socket, :mention_suggestions, [])

        query ->
          suggestions =
            socket.assigns.participants
            |> Enum.reject(&(&1.id == socket.assigns.current_user.id))
            |> Enum.filter(&matches_query?(&1, query))
            |> Enum.take(5)

          assign(socket, :mention_suggestions, suggestions)
      end
    else
      socket
    end
  end

  defp mention_query(body) do
    case Regex.run(@mention_regex, body) do
      [_, query] -> query
      _ -> nil
    end
  end

  defp matches_query?(_account, ""), do: true

  defp matches_query?(account, query) do
    query = String.downcase(query)

    String.contains?(String.downcase(Identity.display_name(account)), query) or
      String.contains?(String.downcase(account.login), query)
  end

  defp maybe_broadcast_typing(socket) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_typing_broadcast_at

    if is_nil(last) or now - last > @typing_throttle_ms do
      Messaging.broadcast_typing(socket.assigns.current_user, socket.assigns.conversation)
      assign(socket, :last_typing_broadcast_at, now)
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form
      phx-change="typing"
      phx-submit="send"
      phx-target={@myself}
      id={@id}
      class="flex items-end gap-2"
    >
      <div class="flex-1 relative">
        <ul
          :if={@mention_suggestions != []}
          class="absolute bottom-full mb-1 left-0 z-10 w-full max-w-xs bg-base-100 border border-base-300 rounded-box shadow-lg max-h-48 overflow-y-auto"
        >
          <li :for={account <- @mention_suggestions}>
            <button
              type="button"
              class="w-full text-left px-3 py-2 hover:bg-base-200 text-sm flex items-center justify-between gap-2"
              phx-click="pick_mention"
              phx-value-account_id={account.id}
              phx-target={@myself}
            >
              <span class="font-bold">{Identity.display_name(account)}</span>
              <span class="text-base-content/50">@{account.login}</span>
            </button>
          </li>
        </ul>

        <textarea
          name="body"
          id={"#{@id}-input"}
          rows="1"
          class="textarea textarea-bordered w-full resize-none"
          placeholder={gettext("Write a message...")}
          maxlength={Message.max_length()}
          phx-debounce="300"
        >{@body}</textarea>
        <div class={[
          "text-right text-xs mt-0.5",
          String.length(@body) >= Message.max_length() && "text-error",
          String.length(@body) < Message.max_length() && "text-base-content/40"
        ]}>
          {String.length(@body)}/{Message.max_length()}
        </div>
      </div>
      <button type="submit" class="btn btn-primary btn-square" disabled={String.trim(@body) == ""}>
        <.icon name="hero-paper-airplane" class="size-5" />
      </button>
    </form>
    """
  end
end
