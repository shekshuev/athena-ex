defmodule AthenaWeb.MessengerLive.IndexTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Messaging

  @script_payload "<script>alert('xss')</script>"
  @img_payload "<img src=x onerror=alert(1)>"

  setup %{conn: conn} do
    alice = insert(:account)
    bob = insert(:account)
    {:ok, conversation} = Messaging.find_or_create_direct_conversation(alice, bob.id)

    conn = init_test_session(conn, %{"account_id" => alice.id})
    %{conn: conn, alice: alice, bob: bob, conversation: conversation}
  end

  describe "Sender display (name, avatar, profile link)" do
    test "every message shows the sender's display name and links to their profile", %{
      conn: conn,
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      {:ok, _} = Messaging.post_message(alice, conversation, %{"body" => "hi bob"})
      {:ok, _} = Messaging.post_message(bob, conversation, %{"body" => "hi alice"})

      {:ok, _lv, html} = live(conn, ~p"/messenger/#{conversation.id}")

      assert html =~ Athena.Identity.display_name(alice)
      assert html =~ Athena.Identity.display_name(bob)
      assert html =~ ~s(href="/profile/#{alice.id}")
      assert html =~ ~s(href="/profile/#{bob.id}")
    end
  end

  describe "XSS: message body" do
    test "a <script> tag sent as a message body is rendered as inert text, not executed markup",
         %{conn: conn, alice: alice, conversation: conversation} do
      {:ok, _message} =
        Messaging.post_message(alice, conversation, %{"body" => @script_payload})

      {:ok, _lv, html} = live(conn, ~p"/messenger/#{conversation.id}")

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;alert"
    end

    test "an onerror image payload sent via the composer's 'send' event is escaped on render", %{
      conn: conn,
      conversation: conversation
    } do
      {:ok, lv, _html} = live(conn, ~p"/messenger/#{conversation.id}")

      lv
      |> form("#composer-#{conversation.id}")
      |> render_submit(%{"body" => @img_payload})

      # "send" broadcasts the new message over PubSub rather than updating
      # the thread inline, so the effect only lands on the *next* render
      # after the LiveView processes that message from its own mailbox.
      html = render(lv)

      refute html =~ "<img src=x onerror"
      assert html =~ "&lt;img src=x onerror"
    end

    test "a script payload survives editing a message and stays escaped", %{
      conn: conn,
      alice: alice,
      conversation: conversation
    } do
      {:ok, message} = Messaging.post_message(alice, conversation, %{"body" => "hello"})

      {:ok, lv, _html} = live(conn, ~p"/messenger/#{conversation.id}")

      lv
      |> element("form[phx-submit*='save_edit']")
      |> render_submit(%{"id" => message.id, "body" => @script_payload})

      html = render(lv)

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;alert"
    end
  end

  describe "XSS: @mention highlighting (the one spot that uses raw HTML)" do
    test "a mention's matched text is escaped even though it's wrapped in <mark> via raw HTML", %{
      conn: conn,
      alice: alice,
      bob: bob,
      conversation: conversation
    } do
      # `matched_text` is normally "@Display Name", built server-side
      # (`Messaging.post_message/3`) from the mentioned account's own
      # display name - if that name itself contains markup (a malicious or
      # careless profile edit), it must still come out escaped despite
      # being wrapped in `Phoenix.HTML.raw/1` for the `<mark>` highlight.
      insert(:profile, owner: bob, first_name: @script_payload)
      bob_with_profile = Athena.Identity.get_accounts_map([bob.id]) |> Map.fetch!(bob.id)
      mention_text = "@" <> Athena.Identity.display_name(bob_with_profile)

      {:ok, _message} =
        Messaging.post_message(alice, conversation, %{
          "body" => "hey " <> mention_text,
          "mention_account_ids" => [bob.id]
        })

      {:ok, _lv, html} = live(conn, ~p"/messenger/#{conversation.id}")

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;alert"
      assert html =~ "mark"
    end
  end

  describe "XSS: sender name and profile fields" do
    test "a malicious profile full name is escaped wherever the sender is shown", %{
      conn: conn,
      bob: bob,
      conversation: conversation
    } do
      insert(:profile, owner: bob, first_name: @script_payload, last_name: "Bobson")

      {:ok, _message} = Messaging.post_message(bob, conversation, %{"body" => "hi from bob"})

      {:ok, _lv, html} = live(conn, ~p"/messenger/#{conversation.id}")

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;alert"
    end

    test "a malicious login is escaped in the cohort @mention dropdown", %{conn: conn} do
      malicious_login = "<script>alert('login')</script>"
      cohort = insert(:cohort)
      target = insert(:account, login: malicious_login)

      alice = insert(:account)
      Messaging.add_cohort_participant(cohort.id, alice.id)
      Messaging.add_cohort_participant(cohort.id, target.id)

      {:ok, conversation} = Messaging.ensure_cohort_conversation(cohort)

      conn = init_test_session(conn, %{"account_id" => alice.id})
      {:ok, lv, _html} = live(conn, ~p"/messenger/#{conversation.id}")

      html =
        lv
        |> form("#composer-#{conversation.id}")
        |> render_change(%{"body" => "@script"})

      refute html =~ "<script>alert('login')"
      assert html =~ "&lt;script&gt;alert"
    end
  end

  describe "Enter-to-send server-side handlers (no JS runtime here, but the events they push are real)" do
    test "picking the keyboard-highlighted mention inserts it and clears suggestions", %{
      conn: conn
    } do
      cohort = insert(:cohort)
      alice = insert(:account)
      bob = insert(:account, login: "bob_the_builder")

      Messaging.add_cohort_participant(cohort.id, alice.id)
      Messaging.add_cohort_participant(cohort.id, bob.id)
      {:ok, conversation} = Messaging.ensure_cohort_conversation(cohort)

      conn = init_test_session(conn, %{"account_id" => alice.id})
      {:ok, lv, _html} = live(conn, ~p"/messenger/#{conversation.id}")

      lv
      |> form("#composer-#{conversation.id}")
      |> render_change(%{"body" => "hey @bob"})

      assert render(lv) =~ "bob_the_builder"

      html =
        lv
        |> element("#composer-#{conversation.id}-input")
        |> render_hook("select_highlighted_mention", %{})

      assert html =~ "hey @" <> Athena.Identity.display_name(bob)
    end

    test "moving the highlight wraps around instead of crashing", %{conn: conn} do
      cohort = insert(:cohort)
      alice = insert(:account)
      bob = insert(:account, login: "bob")
      carol = insert(:account, login: "carol")

      Messaging.add_cohort_participant(cohort.id, alice.id)
      Messaging.add_cohort_participant(cohort.id, bob.id)
      Messaging.add_cohort_participant(cohort.id, carol.id)
      {:ok, conversation} = Messaging.ensure_cohort_conversation(cohort)

      conn = init_test_session(conn, %{"account_id" => alice.id})
      {:ok, lv, _html} = live(conn, ~p"/messenger/#{conversation.id}")

      lv
      |> form("#composer-#{conversation.id}")
      |> render_change(%{"body" => "@"})

      composer_input = element(lv, "#composer-#{conversation.id}-input")
      assert render_hook(composer_input, "move_highlight", %{"direction" => "up"})
      assert render_hook(composer_input, "move_highlight", %{"direction" => "down"})
    end

    test "moving the highlight with no suggestions open is a no-op", %{
      conn: conn,
      conversation: conversation
    } do
      {:ok, lv, _html} = live(conn, ~p"/messenger/#{conversation.id}")

      assert lv
             |> element("#composer-#{conversation.id}-input")
             |> render_hook("move_highlight", %{"direction" => "down"})
    end
  end
end
