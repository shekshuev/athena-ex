defmodule Athena.Messaging.MessagesTest do
  use Athena.DataCase, async: true

  alias Athena.Messaging
  alias Athena.Messaging.Message
  import Athena.Factory

  setup do
    alice = insert(:account)
    bob = insert(:account)
    {:ok, conversation} = Messaging.find_or_create_direct_conversation(alice, bob.id)

    %{alice: alice, bob: bob, conversation: conversation}
  end

  describe "post_message/3" do
    test "posts a message from a participant", %{alice: alice, conversation: conversation} do
      assert {:ok, %Message{body: "hello"}} =
               Messaging.post_message(alice, conversation, %{"body" => "hello"})
    end

    test "rejects a non-participant", %{conversation: conversation} do
      stranger = insert(:account)

      assert {:error, :forbidden} =
               Messaging.post_message(stranger, conversation, %{"body" => "hi"})
    end

    test "rejects an empty body", %{alice: alice, conversation: conversation} do
      assert {:error, changeset} = Messaging.post_message(alice, conversation, %{"body" => "   "})
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a body over the max length", %{alice: alice, conversation: conversation} do
      too_long = String.duplicate("a", Message.max_length() + 1)

      assert {:error, changeset} =
               Messaging.post_message(alice, conversation, %{"body" => too_long})

      assert %{body: [message]} = errors_on(changeset)
      assert message =~ "should be at most"
    end

    test "accepts a body at exactly the max length", %{alice: alice, conversation: conversation} do
      exactly_max = String.duplicate("a", Message.max_length())

      assert {:ok, _message} =
               Messaging.post_message(alice, conversation, %{"body" => exactly_max})
    end

    test "persists mentions with matched display text", %{
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      {:ok, message} =
        Messaging.post_message(alice, conversation, %{
          "body" => "hey @bob",
          "mention_account_ids" => [bob.id]
        })

      assert [%{account_id: mentioned_id, matched_text: "@" <> _}] = message.mentions
      assert mentioned_id == bob.id
    end
  end

  describe "edit_message/3 and delete_message/2" do
    test "the author can edit their own message", %{alice: alice, conversation: conversation} do
      {:ok, message} = Messaging.post_message(alice, conversation, %{"body" => "original"})

      assert {:ok, updated} = Messaging.edit_message(alice, message, %{"body" => "edited"})
      assert updated.body == "edited"
      assert updated.edited_at
    end

    test "another participant cannot edit someone else's message", %{
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      {:ok, message} = Messaging.post_message(alice, conversation, %{"body" => "original"})

      assert {:error, :forbidden} = Messaging.edit_message(bob, message, %{"body" => "hacked"})
    end

    test "the author can delete their own message, blanking its body", %{
      alice: alice,
      conversation: conversation
    } do
      {:ok, message} = Messaging.post_message(alice, conversation, %{"body" => "secret"})

      assert {:ok, deleted} = Messaging.delete_message(alice, message)
      assert deleted.deleted_at
      assert deleted.body == ""
    end

    test "a deleted message cannot be edited again", %{alice: alice, conversation: conversation} do
      {:ok, message} = Messaging.post_message(alice, conversation, %{"body" => "secret"})
      {:ok, deleted} = Messaging.delete_message(alice, message)

      assert {:error, :forbidden} = Messaging.edit_message(alice, deleted, %{"body" => "back"})
    end
  end

  describe "list_messages/2" do
    test "returns messages oldest-first with sender enrichment", %{
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      {:ok, _} = Messaging.post_message(alice, conversation, %{"body" => "first"})
      {:ok, _} = Messaging.post_message(bob, conversation, %{"body" => "second"})

      [first, second] = Messaging.list_messages(conversation)
      assert first.body == "first"
      assert first.account.id == alice.id
      assert second.body == "second"
    end
  end
end
