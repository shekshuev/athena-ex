defmodule Athena.Gamification.DailyChallengesTest do
  use Athena.DataCase, async: true

  alias Athena.Gamification.{DailyChallenges, DailyChallenge, XpEvent}
  alias Athena.Learning.Progress
  alias Athena.Repo
  import Athena.Factory

  describe "today_for/1" do
    test "returns nil when the account has no enrollments at all" do
      account = insert(:account)
      assert DailyChallenges.today_for(account.id) == nil
    end

    test "returns nil when nothing eligible has been completed yet" do
      account = insert(:account)
      section = insert(:section)
      block = insert(:block, section: section, type: :code)
      insert(:enrollment, account_id: account.id, course_id: section.course.id)

      # Enrolled, but never solved it.
      refute DailyChallenges.today_for(account.id)
      # solving it makes it eligible:
      Progress.mark_completed(account.id, block.id)
      assert %DailyChallenge{block_id: block_id} = DailyChallenges.today_for(account.id)
      assert block_id == block.id
    end

    test "only picks code/quiz_question blocks, never file_assignment/exam/passive types" do
      account = insert(:account)
      section = insert(:section)
      course = section.course
      insert(:enrollment, account_id: account.id, course_id: course.id)

      ineligible_types = [:file_assignment, :quiz_exam, :ticket_exam, :text, :video, :image]

      for type <- ineligible_types do
        block = insert(:block, section: section, type: type)
        Progress.mark_completed(account.id, block.id)
      end

      assert DailyChallenges.today_for(account.id) == nil
    end

    test "only picks a completed block from a course the account is enrolled in" do
      account = insert(:account)

      other_section = insert(:section)
      other_block = insert(:block, section: other_section, type: :code)
      # Completed, but the account isn't enrolled in this course.
      Progress.mark_completed(account.id, other_block.id)

      assert DailyChallenges.today_for(account.id) == nil
    end

    test "is idempotent for the same day — repeated calls return the same challenge" do
      account = insert(:account)
      section = insert(:section)
      block = insert(:block, section: section, type: :code)
      insert(:enrollment, account_id: account.id, course_id: section.course.id)
      Progress.mark_completed(account.id, block.id)

      first = DailyChallenges.today_for(account.id)
      second = DailyChallenges.today_for(account.id)

      assert first.id == second.id
      assert Repo.aggregate(DailyChallenge, :count) == 1
    end
  end

  describe "handle_block_completed/1" do
    test "marks today's challenge complete, awards XP, and tags the submission" do
      account = insert(:account)
      section = insert(:section)
      block = insert(:block, section: section, type: :code)
      insert(:enrollment, account_id: account.id, course_id: section.course.id)
      Progress.mark_completed(account.id, block.id)

      challenge = DailyChallenges.today_for(account.id)
      assert challenge.completed_at == nil

      submission =
        insert(:submission, account_id: account.id, block_id: block.id, status: :accepted)

      DailyChallenges.handle_block_completed(%{
        account_id: account.id,
        block_id: block.id,
        block_type: :code,
        cohort_id: nil
      })

      updated = Repo.get!(DailyChallenge, challenge.id)
      assert updated.completed_at

      assert Repo.get_by(XpEvent,
               account_id: account.id,
               source_type: :daily_challenge,
               source_id: challenge.id
             )

      assert Repo.get!(Athena.Learning.Submission, submission.id).origin == :daily_challenge
    end

    test "is a no-op for an unrelated block completion" do
      account = insert(:account)
      section = insert(:section)
      block = insert(:block, section: section, type: :code)
      insert(:enrollment, account_id: account.id, course_id: section.course.id)
      Progress.mark_completed(account.id, block.id)

      DailyChallenges.today_for(account.id)

      other_block = insert(:block, type: :code)

      assert :ok =
               DailyChallenges.handle_block_completed(%{
                 account_id: account.id,
                 block_id: other_block.id,
                 block_type: :code,
                 cohort_id: nil
               })

      refute Repo.get_by(XpEvent, account_id: account.id, source_type: :daily_challenge)
    end

    test "only awards XP once even if the completion event fires twice" do
      account = insert(:account)
      section = insert(:section)
      block = insert(:block, section: section, type: :code)
      insert(:enrollment, account_id: account.id, course_id: section.course.id)
      Progress.mark_completed(account.id, block.id)

      challenge = DailyChallenges.today_for(account.id)
      xp_before = Athena.Gamification.total_xp(account.id)

      payload = %{account_id: account.id, block_id: block.id, block_type: :code, cohort_id: nil}
      DailyChallenges.handle_block_completed(payload)
      DailyChallenges.handle_block_completed(payload)

      assert Repo.aggregate(
               from(e in XpEvent, where: e.source_type == :daily_challenge),
               :count
             ) == 1

      # 15 is the seeded base XP amount for a :code block — awarded exactly
      # once despite handle_block_completed/1 being called twice.
      assert Athena.Gamification.total_xp(account.id) == xp_before + 15
      assert Repo.get!(DailyChallenge, challenge.id).completed_at
    end
  end
end
