defmodule Athena.Messaging do
  @moduledoc """
  Public API for the Messaging context: direct (1:1) and cohort group text
  chat.
  """

  alias Athena.Messaging.{Conversations, Messages}

  defdelegate list_conversations(user), to: Conversations
  defdelegate get_conversation(user, id), to: Conversations
  defdelegate find_or_create_direct_conversation(user, other_account_id), to: Conversations
  defdelegate mark_read(user, conversation), to: Conversations
  defdelegate count_unread_conversations(user), to: Conversations
  defdelegate list_participant_accounts(conversation), to: Conversations

  # Cohort-lifecycle hook points, called from Athena.Learning.Cohorts.
  defdelegate ensure_cohort_conversation(cohort), to: Conversations
  defdelegate add_cohort_participant(cohort_id, account_id), to: Conversations
  defdelegate remove_cohort_participant(cohort_id, account_id), to: Conversations

  defdelegate get_message(id), to: Messages
  defdelegate list_messages(conversation, opts \\ []), to: Messages
  defdelegate post_message(user, conversation, attrs), to: Messages
  defdelegate edit_message(user, message, attrs \\ %{}), to: Messages
  defdelegate delete_message(user, message), to: Messages
  defdelegate broadcast_typing(user, conversation), to: Messages
end
