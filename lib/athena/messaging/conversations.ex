defmodule Athena.Messaging.Conversations do
  @moduledoc """
  Internal business logic for conversations: listing a user's inbox with
  unread/mention state, finding-or-creating direct (1:1) conversations, and
  keeping a cohort's group chat participants in sync with its membership.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Identity
  alias Athena.Learning
  alias Athena.Messaging.{Conversation, ConversationParticipant, Message, MessageMention}

  @doc """
  Lists all conversations the given account participates in, ordered by
  most recent activity, enriched with the other DM participant (or cohort),
  unread counts, unread-mention flags, and a last-message preview.
  """
  @spec list_conversations(map()) :: [Conversation.t()]
  def list_conversations(user) do
    from(cp in ConversationParticipant,
      join: c in Conversation,
      on: c.id == cp.conversation_id,
      where: cp.account_id == ^user.id,
      order_by: [desc_nulls_last: c.last_message_at, desc: c.inserted_at],
      select: c
    )
    |> Repo.all()
    |> enrich_conversations(user)
  end

  @doc """
  Fetches a single conversation for the given user, provided they are a
  participant. Returns `{:error, :not_found}` otherwise — conversations are
  private, there is no admin/moderation override.
  """
  @spec get_conversation(map(), String.t()) :: {:ok, Conversation.t()} | {:error, :not_found}
  def get_conversation(user, id) do
    participant = Repo.get_by(ConversationParticipant, conversation_id: id, account_id: user.id)
    conversation = participant && Repo.get(Conversation, id)

    case conversation do
      nil ->
        {:error, :not_found}

      conversation ->
        [enriched] = enrich_conversations([conversation], user)
        {:ok, enriched}
    end
  end

  @doc """
  Finds the existing direct conversation between `user` and
  `other_account_id`, or creates it (idempotent, race-safe via the
  `conversations.direct_key` unique index).
  """
  @spec find_or_create_direct_conversation(map(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :cannot_message_self | :not_found | :invalid}
  def find_or_create_direct_conversation(%{id: user_id}, user_id),
    do: {:error, :cannot_message_self}

  def find_or_create_direct_conversation(%{id: user_id}, other_account_id) do
    case Identity.get_account(other_account_id) do
      {:ok, %{status: :active}} ->
        direct_key = build_direct_key(user_id, other_account_id)

        case Repo.get_by(Conversation, direct_key: direct_key) do
          nil -> insert_direct_conversation(direct_key, user_id, other_account_id)
          conversation -> {:ok, conversation}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Marks a conversation as read (up to now) for the given user, and notifies
  their other sessions/tabs so the unread badge updates live.
  """
  @spec mark_read(map(), Conversation.t()) :: :ok
  def mark_read(user, conversation) do
    now = DateTime.utc_now()

    from(cp in ConversationParticipant,
      where: cp.conversation_id == ^conversation.id and cp.account_id == ^user.id
    )
    |> Repo.update_all(set: [last_read_at: now])

    Phoenix.PubSub.broadcast(Athena.PubSub, "inbox:#{user.id}", {:inbox_updated, conversation.id})

    :ok
  end

  @doc """
  Counts how many of the user's conversations have at least one unread
  message — used for the sidebar badge.
  """
  @spec count_unread_conversations(map()) :: non_neg_integer()
  def count_unread_conversations(user) do
    conversation_ids =
      from(cp in ConversationParticipant,
        where: cp.account_id == ^user.id,
        select: cp.conversation_id
      )
      |> Repo.all()

    conversation_ids
    |> unread_counts_by_conversation(user.id)
    |> map_size()
  end

  @doc """
  Lists the accounts participating in a conversation — used to power the
  `@mention` autocomplete in cohort chats.
  """
  @spec list_participant_accounts(Conversation.t()) :: [Athena.Identity.Account.t()]
  def list_participant_accounts(conversation) do
    account_ids =
      from(cp in ConversationParticipant,
        where: cp.conversation_id == ^conversation.id,
        select: cp.account_id
      )
      |> Repo.all()

    account_ids |> Identity.get_accounts_map() |> Map.values()
  end

  @doc """
  Ensures the given cohort has a group conversation, creating one if needed.
  Idempotent and safe to call repeatedly.
  """
  @spec ensure_cohort_conversation(Learning.Cohort.t()) :: {:ok, Conversation.t()}
  def ensure_cohort_conversation(cohort) do
    case Repo.get_by(Conversation, cohort_id: cohort.id) do
      nil ->
        %Conversation{}
        |> Conversation.changeset(%{kind: :cohort, cohort_id: cohort.id})
        |> Repo.insert()
        |> case do
          {:ok, conversation} ->
            {:ok, conversation}

          {:error, _changeset} ->
            # Race: another process created it concurrently.
            {:ok, Repo.get_by!(Conversation, cohort_id: cohort.id)}
        end

      conversation ->
        {:ok, conversation}
    end
  end

  @doc """
  Adds an account as a participant of the given cohort's group conversation
  (creating the conversation first if needed). Idempotent.
  """
  @spec add_cohort_participant(String.t(), String.t()) :: :ok
  def add_cohort_participant(cohort_id, account_id) do
    {:ok, conversation} = ensure_cohort_conversation(%Learning.Cohort{id: cohort_id})

    %ConversationParticipant{}
    |> ConversationParticipant.changeset(%{
      conversation_id: conversation.id,
      account_id: account_id
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:conversation_id, :account_id])

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "conversation:#{conversation.id}",
      {:conversation_participants_changed, conversation.id}
    )

    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "inbox:#{account_id}",
      {:inbox_updated, conversation.id}
    )

    :ok
  end

  @doc """
  Removes an account from the given cohort's group conversation. Message
  history is untouched (senders are referenced by a soft `account_id`).
  """
  @spec remove_cohort_participant(String.t(), String.t()) :: :ok
  def remove_cohort_participant(cohort_id, account_id) do
    case Repo.get_by(Conversation, cohort_id: cohort_id) do
      nil ->
        :ok

      conversation ->
        from(cp in ConversationParticipant,
          where: cp.conversation_id == ^conversation.id and cp.account_id == ^account_id
        )
        |> Repo.delete_all()

        Phoenix.PubSub.broadcast(
          Athena.PubSub,
          "conversation:#{conversation.id}",
          {:conversation_participants_changed, conversation.id}
        )

        Phoenix.PubSub.broadcast(
          Athena.PubSub,
          "inbox:#{account_id}",
          {:inbox_updated, conversation.id}
        )

        :ok
    end
  end

  # -- internal --------------------------------------------------------

  defp build_direct_key(a, b), do: Enum.sort([a, b]) |> Enum.join(":")

  defp insert_direct_conversation(direct_key, user_id, other_account_id) do
    result =
      Repo.transaction(fn ->
        with {:ok, conversation} <-
               %Conversation{}
               |> Conversation.changeset(%{kind: :direct, direct_key: direct_key})
               |> Repo.insert(),
             {:ok, _} <-
               %ConversationParticipant{}
               |> ConversationParticipant.changeset(%{
                 conversation_id: conversation.id,
                 account_id: user_id
               })
               |> Repo.insert(),
             {:ok, _} <-
               %ConversationParticipant{}
               |> ConversationParticipant.changeset(%{
                 conversation_id: conversation.id,
                 account_id: other_account_id
               })
               |> Repo.insert() do
          conversation
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, conversation} ->
        {:ok, conversation}

      {:error, %Ecto.Changeset{}} ->
        # Race: someone else created the same DM concurrently — re-fetch it.
        case Repo.get_by(Conversation, direct_key: direct_key) do
          nil -> {:error, :invalid}
          conversation -> {:ok, conversation}
        end
    end
  end

  defp enrich_conversations([], _user), do: []

  defp enrich_conversations(conversations, user) do
    conversation_ids = Enum.map(conversations, & &1.id)
    direct_ids = conversations |> Enum.filter(&(&1.kind == :direct)) |> Enum.map(& &1.id)

    cohort_ids =
      conversations
      |> Enum.filter(&(&1.kind == :cohort))
      |> Enum.map(& &1.cohort_id)
      |> Enum.reject(&is_nil/1)

    other_participants_map = load_other_participants(direct_ids, user.id)
    cohorts_map = if cohort_ids == [], do: %{}, else: Learning.get_cohorts_map(cohort_ids)
    unread_counts = unread_counts_by_conversation(conversation_ids, user.id)
    mentioned_conversation_ids = unread_mentioned_conversation_ids(conversation_ids, user.id)
    last_messages = load_last_messages(conversation_ids)

    Enum.map(conversations, fn conv ->
      conv
      |> put_other_participant(other_participants_map)
      |> put_cohort(cohorts_map)
      |> Map.put(:unread_count, Map.get(unread_counts, conv.id, 0))
      |> Map.put(:has_unread_mention, MapSet.member?(mentioned_conversation_ids, conv.id))
      |> Map.put(:last_message, Map.get(last_messages, conv.id))
    end)
  end

  defp put_other_participant(%{kind: :direct} = conv, map),
    do: %{conv | other_participant: Map.get(map, conv.id)}

  defp put_other_participant(conv, _map), do: conv

  defp put_cohort(%{kind: :cohort} = conv, map),
    do: %{conv | cohort: Map.get(map, conv.cohort_id)}

  defp put_cohort(conv, _map), do: conv

  defp load_other_participants([], _user_id), do: %{}

  defp load_other_participants(direct_ids, user_id) do
    conversation_to_account =
      from(cp in ConversationParticipant,
        where: cp.conversation_id in ^direct_ids and cp.account_id != ^user_id,
        select: {cp.conversation_id, cp.account_id}
      )
      |> Repo.all()
      |> Map.new()

    accounts_map = Identity.get_accounts_map(Map.values(conversation_to_account))

    Map.new(conversation_to_account, fn {conversation_id, account_id} ->
      {conversation_id, Map.get(accounts_map, account_id)}
    end)
  end

  defp unread_counts_by_conversation([], _user_id), do: %{}

  defp unread_counts_by_conversation(conversation_ids, user_id) do
    from(m in Message,
      join: cp in ConversationParticipant,
      on: cp.conversation_id == m.conversation_id and cp.account_id == ^user_id,
      where:
        m.conversation_id in ^conversation_ids and is_nil(m.deleted_at) and
          m.account_id != ^user_id,
      where: is_nil(cp.last_read_at) or m.inserted_at > cp.last_read_at,
      group_by: m.conversation_id,
      select: {m.conversation_id, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp unread_mentioned_conversation_ids([], _user_id), do: MapSet.new()

  defp unread_mentioned_conversation_ids(conversation_ids, user_id) do
    from(mm in MessageMention,
      join: m in Message,
      on: m.id == mm.message_id,
      join: cp in ConversationParticipant,
      on: cp.conversation_id == m.conversation_id and cp.account_id == ^user_id,
      where:
        mm.account_id == ^user_id and m.conversation_id in ^conversation_ids and
          is_nil(m.deleted_at),
      where: is_nil(cp.last_read_at) or m.inserted_at > cp.last_read_at,
      distinct: m.conversation_id,
      select: m.conversation_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp load_last_messages([]), do: %{}

  defp load_last_messages(conversation_ids) do
    accounts_map =
      from(m in Message,
        where: m.conversation_id in ^conversation_ids,
        distinct: m.conversation_id,
        order_by: [asc: m.conversation_id, desc: m.inserted_at],
        select: m.account_id
      )
      |> Repo.all()
      |> Identity.get_accounts_map()

    from(m in Message,
      where: m.conversation_id in ^conversation_ids,
      distinct: m.conversation_id,
      order_by: [asc: m.conversation_id, desc: m.inserted_at]
    )
    |> Repo.all()
    |> Map.new(fn message ->
      {message.conversation_id, %{message | account: Map.get(accounts_map, message.account_id)}}
    end)
  end
end
