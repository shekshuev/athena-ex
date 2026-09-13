defmodule Athena.Messaging.Messages do
  @moduledoc """
  Internal business logic for posting, editing, deleting, and listing
  messages within a conversation, plus lightweight ephemeral typing
  broadcasts.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Identity
  alias Athena.Messaging.{Conversation, ConversationParticipant, Message, MessageMention}

  @doc """
  Fetches a single message by id, regardless of conversation — callers are
  expected to verify it belongs to the conversation they think it does.
  """
  @spec get_message(String.t()) :: {:ok, Message.t()} | {:error, :not_found}
  def get_message(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @doc """
  Lists messages in a conversation, oldest-first, enriched with sender and
  mentions. Pass `before: message` to keyset-paginate backwards (load older
  messages above what's currently rendered).
  """
  @spec list_messages(Conversation.t(), keyword()) :: [Message.t()]
  def list_messages(conversation, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_message = Keyword.get(opts, :before)

    Message
    |> where([m], m.conversation_id == ^conversation.id)
    |> maybe_before(before_message)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> preload(:mentions)
    |> Repo.all()
    |> Enum.reverse()
    |> enrich_senders()
  end

  @doc """
  Posts a new message from `user` into `conversation`, provided they are a
  participant. Persists `@mention`s (from `attrs["mention_account_ids"]`),
  bumps the conversation's `last_message_at`, marks the sender's own copy as
  read, and broadcasts the new message to the conversation topic and an
  inbox update to every other participant.
  """
  @spec post_message(map(), Conversation.t(), map()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()} | {:error, :forbidden}
  def post_message(user, conversation, attrs) do
    if participant?(conversation.id, user.id) do
      mention_account_ids = Map.get(attrs, "mention_account_ids", []) |> List.wrap()

      result =
        Repo.transaction(fn ->
          with {:ok, message} <-
                 %Message{}
                 |> Message.changeset(%{
                   conversation_id: conversation.id,
                   account_id: user.id,
                   body: Map.get(attrs, "body", "")
                 })
                 |> Repo.insert(),
               :ok <- insert_mentions(message, mention_account_ids),
               :ok <- touch_conversation(conversation.id, message.inserted_at),
               :ok <- touch_last_read(conversation.id, user.id, message.inserted_at) do
            message
          else
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, message} ->
          broadcast_and_notify(conversation, message, user)
          {:ok, enrich_message(message)}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Edits `message`'s body, provided `user` is its author and it hasn't been
  deleted. Broadcasts the update to the conversation topic.
  """
  @spec edit_message(map(), Message.t(), map()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()} | {:error, :forbidden}
  def edit_message(user, %Message{} = message, attrs \\ %{}) do
    if own_and_not_deleted?(message, user.id) do
      message
      |> Message.edit_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast(updated, :message_updated)
          {:ok, enrich_message(updated)}

        error ->
          error
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Soft-deletes `message` (blanking its body), provided `user` is its
  author. Broadcasts the update to the conversation topic.
  """
  @spec delete_message(map(), Message.t()) :: {:ok, Message.t()} | {:error, :forbidden}
  def delete_message(user, %Message{} = message) do
    if own_and_not_deleted?(message, user.id) do
      now = DateTime.utc_now()

      message
      |> Ecto.Changeset.change(deleted_at: now, body: "")
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast(updated, :message_updated)
          {:ok, enrich_message(updated)}

        error ->
          error
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Broadcasts an ephemeral "user is typing" event to the conversation topic.
  Not persisted.
  """
  @spec broadcast_typing(map(), Conversation.t()) :: :ok
  def broadcast_typing(user, conversation) do
    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "conversation:#{conversation.id}",
      {:typing, user.id}
    )
  end

  # -- internal --------------------------------------------------------

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, %Message{inserted_at: inserted_at}) do
    where(query, [m], m.inserted_at < ^inserted_at)
  end

  defp participant?(conversation_id, account_id) do
    Repo.exists?(
      from(cp in ConversationParticipant,
        where: cp.conversation_id == ^conversation_id and cp.account_id == ^account_id
      )
    )
  end

  defp own_and_not_deleted?(%Message{account_id: account_id, deleted_at: nil}, account_id),
    do: true

  defp own_and_not_deleted?(_message, _account_id), do: false

  defp insert_mentions(_message, []), do: :ok

  defp insert_mentions(message, mention_account_ids) do
    accounts_map = Identity.get_accounts_map(mention_account_ids)

    Enum.reduce_while(mention_account_ids, :ok, fn account_id, :ok ->
      case Map.get(accounts_map, account_id) do
        nil ->
          {:cont, :ok}

        account ->
          %MessageMention{}
          |> MessageMention.changeset(%{
            message_id: message.id,
            account_id: account_id,
            matched_text: "@" <> Identity.display_name(account)
          })
          |> Repo.insert()
          |> case do
            {:ok, _} -> {:cont, :ok}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
      end
    end)
  end

  defp touch_conversation(conversation_id, inserted_at) do
    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [last_message_at: inserted_at])

    :ok
  end

  defp touch_last_read(conversation_id, account_id, inserted_at) do
    from(cp in ConversationParticipant,
      where: cp.conversation_id == ^conversation_id and cp.account_id == ^account_id
    )
    |> Repo.update_all(set: [last_read_at: inserted_at])

    :ok
  end

  defp broadcast_and_notify(conversation, message, sender) do
    broadcast(message, :new_message)

    other_participant_ids =
      from(cp in ConversationParticipant,
        where: cp.conversation_id == ^conversation.id and cp.account_id != ^sender.id,
        select: cp.account_id
      )
      |> Repo.all()

    notification = %{
      conversation_id: conversation.id,
      title: notification_title(conversation, sender),
      preview: String.slice(message.body || "", 0, 120),
      url: "/messenger/#{conversation.id}"
    }

    Enum.each(other_participant_ids, fn account_id ->
      Phoenix.PubSub.broadcast(
        Athena.PubSub,
        "inbox:#{account_id}",
        {:inbox_updated, conversation.id}
      )

      Phoenix.PubSub.broadcast(
        Athena.PubSub,
        "inbox:#{account_id}",
        {:new_message_notification, notification}
      )
    end)
  end

  defp notification_title(%{kind: :direct}, sender), do: Identity.display_name(sender)

  defp notification_title(%{kind: :cohort, cohort: %{name: name}}, sender),
    do: "#{name} · #{Identity.display_name(sender)}"

  defp notification_title(%{kind: :cohort}, sender), do: Identity.display_name(sender)

  defp broadcast(message, event) do
    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "conversation:#{message.conversation_id}",
      {event, enrich_message(message)}
    )
  end

  defp enrich_senders([]), do: []

  defp enrich_senders(messages) do
    account_ids = messages |> Enum.map(& &1.account_id) |> Enum.uniq()
    accounts_map = Identity.get_accounts_map(account_ids)

    Enum.map(messages, fn message ->
      %{message | account: Map.get(accounts_map, message.account_id)}
    end)
  end

  defp enrich_message(message) do
    message = Repo.preload(message, :mentions, force: true)
    [enriched] = enrich_senders([message])
    enriched
  end
end
