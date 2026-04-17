defmodule Athena.Content.PolicyTest do
  use Athena.DataCase, async: true

  alias Athena.Content.Policy
  alias Athena.Content.AccessRules
  alias Athena.Learning.CohortSchedule
  import Athena.Factory

  setup do
    user = insert(:account)
    %{user: user}
  end

  describe "can_view?/3 (без оверрайдов)" do
    test "always returns true for :all mode", %{user: _user} do
      block = insert(:block, visibility: :hidden)
      assert Policy.can_view?(:all, block) == true
    end

    test "returns true if :enrolled, false if :hidden", %{user: user} do
      open_block = insert(:block, visibility: :enrolled)
      hidden_block = insert(:block, visibility: :hidden)

      assert Policy.can_view?(user, open_block) == true
      assert Policy.can_view?(user, hidden_block) == false
    end

    test "block inherits visibility from parent section", %{user: user} do
      hidden_section = insert(:section, visibility: :hidden)
      open_section = insert(:section, visibility: :enrolled)
      block_in_hidden = insert(:block, section: hidden_section, visibility: :inherit)
      block_in_open = insert(:block, section: open_section, visibility: :inherit)

      assert Policy.can_view?(user, block_in_hidden) == false
      assert Policy.can_view?(user, block_in_open) == true
    end

    test "evaluates global time restrictions (:restricted)", %{user: user} do
      now = DateTime.utc_now()
      past = DateTime.add(now, -1, :day)
      future = DateTime.add(now, 1, :day)

      valid_block =
        insert(:block,
          visibility: :restricted,
          access_rules: %AccessRules{unlock_at: past, lock_at: future}
        )

      future_block =
        insert(:block, visibility: :restricted, access_rules: %AccessRules{unlock_at: future})

      expired_block =
        insert(:block, visibility: :restricted, access_rules: %AccessRules{lock_at: past})

      assert Policy.can_view?(user, valid_block) == true
      assert Policy.can_view?(user, future_block) == false
      assert Policy.can_view?(user, expired_block) == false
    end
  end

  describe "can_view?/3" do
    test "override visibility strictly trumps global visibility", %{user: user} do
      block = insert(:block, visibility: :hidden)

      overrides = [
        %CohortSchedule{resource_type: :block, resource_id: block.id, visibility: :enrolled}
      ]

      assert Policy.can_view?(user, block, overrides) == true
    end

    test "override visibility bypasses parent inheritance", %{user: user} do
      hidden_section = insert(:section, visibility: :hidden)
      block = insert(:block, section: hidden_section, visibility: :inherit)

      overrides = [
        %CohortSchedule{resource_type: :block, resource_id: block.id, visibility: :enrolled}
      ]

      assert Policy.can_view?(user, block, overrides) == true
    end

    test "override time unlocks a globally locked future item", %{user: user} do
      now = DateTime.utc_now()
      past = DateTime.add(now, -1, :day)
      future = DateTime.add(now, 1, :day)

      block =
        insert(:block, visibility: :restricted, access_rules: %AccessRules{unlock_at: future})

      overrides = [
        %CohortSchedule{
          resource_type: :block,
          resource_id: block.id,
          visibility: :restricted,
          unlock_at: past
        }
      ]

      assert Policy.can_view?(user, block, overrides) == true
    end

    test "override lock time aggressively closes a globally open item", %{user: user} do
      now = DateTime.utc_now()
      past = DateTime.add(now, -1, :day)

      block = insert(:block, visibility: :restricted, access_rules: %AccessRules{unlock_at: past})

      overrides = [
        %CohortSchedule{
          resource_type: :block,
          resource_id: block.id,
          visibility: :restricted,
          lock_at: past
        }
      ]

      assert Policy.can_view?(user, block, overrides) == false
    end

    test "ignores overrides for other resources", %{user: user} do
      block = insert(:block, visibility: :hidden)

      overrides = [
        %CohortSchedule{
          resource_type: :block,
          resource_id: Ecto.UUID.generate(),
          visibility: :enrolled
        }
      ]

      assert Policy.can_view?(user, block, overrides) == false
    end
  end
end
