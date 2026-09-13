defmodule Athena.Messaging.ConversationsTest do
  use Athena.DataCase, async: true

  alias Athena.Messaging
  alias Athena.Messaging.{Conversation, ConversationParticipant}
  alias Athena.Repo
  import Athena.Factory

  describe "find_or_create_direct_conversation/2" do
    test "creates a new direct conversation with both participants" do
      alice = insert(:account)
      bob = insert(:account)

      assert {:ok, %Conversation{kind: :direct} = conversation} =
               Messaging.find_or_create_direct_conversation(alice, bob.id)

      participant_ids =
        ConversationParticipant
        |> Repo.all()
        |> Enum.filter(&(&1.conversation_id == conversation.id))
        |> Enum.map(& &1.account_id)
        |> Enum.sort()

      assert participant_ids == Enum.sort([alice.id, bob.id])
    end

    test "is idempotent regardless of argument order" do
      alice = insert(:account)
      bob = insert(:account)

      {:ok, conv1} = Messaging.find_or_create_direct_conversation(alice, bob.id)
      {:ok, conv2} = Messaging.find_or_create_direct_conversation(bob, alice.id)

      assert conv1.id == conv2.id
      assert Repo.aggregate(Conversation, :count) == 1
    end

    test "refuses to message yourself" do
      alice = insert(:account)

      assert {:error, :cannot_message_self} =
               Messaging.find_or_create_direct_conversation(alice, alice.id)
    end

    test "returns not_found for a missing account" do
      alice = insert(:account)

      assert {:error, :not_found} =
               Messaging.find_or_create_direct_conversation(alice, Ecto.UUID.generate())
    end
  end

  describe "list_conversations/1 and unread tracking" do
    test "lists only the user's own conversations, most recent first" do
      alice = insert(:account)
      bob = insert(:account)
      carol = insert(:account)

      {:ok, conv_with_bob} = Messaging.find_or_create_direct_conversation(alice, bob.id)
      {:ok, _conv_with_nobody} = Messaging.find_or_create_direct_conversation(bob, carol.id)

      Messaging.post_message(bob, conv_with_bob, %{"body" => "hi"})

      [conversation] = Messaging.list_conversations(alice)
      assert conversation.id == conv_with_bob.id
      assert conversation.other_participant.id == bob.id
      assert conversation.unread_count == 1
    end

    test "mark_read/2 clears the unread count" do
      alice = insert(:account)
      bob = insert(:account)

      {:ok, conversation} = Messaging.find_or_create_direct_conversation(alice, bob.id)
      Messaging.post_message(bob, conversation, %{"body" => "hi"})

      Messaging.mark_read(alice, conversation)

      [reloaded] = Messaging.list_conversations(alice)
      assert reloaded.unread_count == 0
      assert Messaging.count_unread_conversations(alice) == 0
    end

    test "get_last_read_at/2 reflects the cursor before and after mark_read/2" do
      alice = insert(:account)
      bob = insert(:account)

      {:ok, conversation} = Messaging.find_or_create_direct_conversation(alice, bob.id)
      assert Messaging.get_last_read_at(alice, conversation) == nil

      Messaging.post_message(bob, conversation, %{"body" => "hi"})
      Messaging.mark_read(alice, conversation)

      assert %DateTime{} = Messaging.get_last_read_at(alice, conversation)
    end

    test "count_unread_conversations/1 counts conversations, not messages" do
      alice = insert(:account)
      bob = insert(:account)

      {:ok, conversation} = Messaging.find_or_create_direct_conversation(alice, bob.id)
      Messaging.post_message(bob, conversation, %{"body" => "one"})
      Messaging.post_message(bob, conversation, %{"body" => "two"})

      assert Messaging.count_unread_conversations(alice) == 1
    end
  end

  describe "cohort conversation lifecycle" do
    test "ensure_cohort_conversation/1 is idempotent" do
      cohort = insert(:cohort)

      {:ok, conv1} = Messaging.ensure_cohort_conversation(cohort)
      {:ok, conv2} = Messaging.ensure_cohort_conversation(cohort)

      assert conv1.id == conv2.id
      assert conv1.kind == :cohort
    end

    test "add_cohort_participant/2 and remove_cohort_participant/2 sync membership" do
      cohort = insert(:cohort)
      account = insert(:account)

      Messaging.add_cohort_participant(cohort.id, account.id)
      {:ok, conversation} = Messaging.get_conversation(account, cohort_conversation_id(cohort))
      assert conversation.cohort.id == cohort.id

      Messaging.remove_cohort_participant(cohort.id, account.id)
      assert {:error, :not_found} = Messaging.get_conversation(account, conversation.id)
    end
  end

  defp cohort_conversation_id(cohort) do
    Repo.get_by!(Conversation, cohort_id: cohort.id).id
  end
end
