defmodule Athena.Learning.ProgressTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Progress
  alias Athena.Learning.BlockProgress
  alias Athena.Content.CompletionRule
  import Athena.Factory

  setup do
    user = insert(:account)
    team = insert(:cohort, type: :team)
    %{user: user, team: team}
  end

  describe "mark_completed/3" do
    test "records individual block progress (UPSERT)", %{user: user} do
      block = insert(:block)

      assert {:ok, %BlockProgress{} = progress} = Progress.mark_completed(user.id, block.id)
      assert progress.account_id == user.id
      assert progress.block_id == block.id
      assert progress.status == :completed
      assert progress.cohort_id == nil

      assert {:ok, %BlockProgress{}} = Progress.mark_completed(user.id, block.id)
    end

    test "records team block progress (UPSERT with partial index)", %{user: user, team: team} do
      block = insert(:block)

      assert {:ok, %BlockProgress{} = progress} =
               Progress.mark_completed(user.id, block.id, team.id)

      assert progress.account_id == user.id
      assert progress.block_id == block.id
      assert progress.cohort_id == team.id
      assert {:ok, %BlockProgress{}} = Progress.mark_completed(user.id, block.id, team.id)
    end
  end

  describe "completed_block_ids/3" do
    test "fetches only individual completions, ignoring team ones", %{user: user, team: team} do
      section = insert(:section)
      block1 = insert(:block, section: section)
      block2 = insert(:block, section: section)

      Progress.mark_completed(user.id, block1.id)
      Progress.mark_completed(user.id, block2.id, team.id)

      ids = Progress.completed_block_ids(user.id, section.id)
      assert block1.id in ids
      refute block2.id in ids
    end

    test "fetches only team completions, ignoring individual ones", %{user: user, team: team} do
      section = insert(:section)
      block1 = insert(:block, section: section)
      block2 = insert(:block, section: section)

      Progress.mark_completed(user.id, block1.id)
      Progress.mark_completed(user.id, block2.id, team.id)

      ids = Progress.completed_block_ids(user.id, section.id, team.id)
      refute block1.id in ids
      assert block2.id in ids
    end
  end

  describe "accessible_section_ids/5 (Retrograde Locking)" do
    test "grants access to everything if there are no gates", %{user: user} do
      course = insert(:course)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      insert(:block, section: s1)

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2])
      assert s1.id in accessible
      assert s2.id in accessible
    end

    test "halts access at the first section with an uncompleted gate", %{user: user} do
      course = insert(:course)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)
      s3 = insert(:section, course: course)

      gate_block = insert(:block, section: s2, completion_rule: %CompletionRule{type: :button})

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])
      assert s1.id in accessible
      assert s2.id in accessible
      refute s3.id in accessible

      Progress.mark_completed(user.id, gate_block.id)

      new_accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])
      assert s3.id in new_accessible
    end

    test "respects team progress for gates on competitions", %{user: user, team: team} do
      course = insert(:course, type: :competition)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      gate_block = insert(:block, section: s1, completion_rule: %CompletionRule{type: :submit})

      Progress.mark_completed(user.id, gate_block.id)

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2], [], team.id)
      assert s1.id in accessible
      refute s2.id in accessible

      Progress.mark_completed(user.id, gate_block.id, team.id)

      new_accessible = Progress.accessible_section_ids(user, course.id, [s1, s2], [], team.id)
      assert s2.id in new_accessible
    end

    test "ignores hidden blocks even if they have completion rules (gates)", %{user: user} do
      course = insert(:course)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      gate_visible = insert(:block, section: s1, completion_rule: %CompletionRule{type: :button})

      _gate_hidden =
        insert(:block,
          section: s2,
          visibility: :hidden,
          completion_rule: %CompletionRule{type: :submit}
        )

      s3 = insert(:section, course: course)

      accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])
      assert s1.id in accessible
      refute s2.id in accessible

      Progress.mark_completed(user.id, gate_visible.id)

      new_accessible = Progress.accessible_section_ids(user, course.id, [s1, s2, s3])
      assert s2.id in new_accessible
      assert s3.id in new_accessible
    end
  end
end
