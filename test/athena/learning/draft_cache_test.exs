defmodule Athena.Learning.DraftCacheTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.DraftCache

  describe "save_draft/4 and get_draft/3" do
    test "saves and retrieves individual draft" do
      user_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      content = %{"text_answer" => "Draft 1"}

      assert :ok = DraftCache.save_draft(user_id, nil, block_id, content)
      assert DraftCache.get_draft(user_id, nil, block_id) == content
    end

    test "saves and retrieves team draft" do
      user_id = Ecto.UUID.generate()
      team_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      content = %{"text_answer" => "Team Draft"}

      assert :ok = DraftCache.save_draft(user_id, team_id, block_id, content)
      assert DraftCache.get_draft(user_id, team_id, block_id) == content

      other_user_id = Ecto.UUID.generate()
      assert DraftCache.get_draft(other_user_id, team_id, block_id) == content
    end

    test "overwrites existing draft" do
      user_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      DraftCache.save_draft(user_id, nil, block_id, %{"v" => 1})
      DraftCache.save_draft(user_id, nil, block_id, %{"v" => 2})

      assert DraftCache.get_draft(user_id, nil, block_id) == %{"v" => 2}
    end

    test "returns nil for non-existent draft" do
      user_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      assert DraftCache.get_draft(user_id, nil, block_id) == nil
    end
  end

  describe "clear_draft/3" do
    test "removes draft from cache" do
      user_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      content = %{"answer" => "test"}

      DraftCache.save_draft(user_id, nil, block_id, content)
      assert DraftCache.get_draft(user_id, nil, block_id) == content

      assert :ok = DraftCache.clear_draft(user_id, nil, block_id)
      assert DraftCache.get_draft(user_id, nil, block_id) == nil
    end

    test "does not error on non-existent draft" do
      user_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      assert :ok = DraftCache.clear_draft(user_id, nil, block_id)
    end
  end

  describe "draft_exists?/3" do
    test "returns true if draft exists" do
      user_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      DraftCache.save_draft(user_id, nil, block_id, %{})
      assert DraftCache.draft_exists?(user_id, nil, block_id) == true
    end

    test "returns false if draft does not exist" do
      user_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      assert DraftCache.draft_exists?(user_id, nil, block_id) == false
    end
  end

  describe "broadcast and subscription" do
    test "subscribes and receives draft updates for team" do
      team_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()
      updater_id = Ecto.UUID.generate()
      content = %{"text" => "Live update"}

      assert :ok = DraftCache.subscribe_to_draft_updates(team_id, block_id)

      DraftCache.broadcast_draft_update(team_id, block_id, content, updater_id)

      assert_receive {:draft_updated,
                      %{block_id: ^block_id, content: ^content, updater_id: ^updater_id}}
    end

    test "ignores broadcasts for individual drafts (no team_id)" do
      user_id = Ecto.UUID.generate()
      block_id = Ecto.UUID.generate()

      assert :ok = DraftCache.broadcast_draft_update(nil, block_id, %{}, user_id)

      refute_receive {:draft_updated, _}
    end
  end
end
