defmodule Athena.Learning.TestRunsTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.TestRuns
  alias Athena.Learning.{BlockProgress, Enrollment, Submission, TestRunSession}
  alias Athena.Identity.{Account, Role}
  alias Athena.Content.CompletionRule
  alias Athena.Repo
  import Athena.Factory

  setup do
    instructor = insert(:account)
    %{instructor: instructor}
  end

  describe "start/3" do
    test "rejects an instructor who can read but not edit the course" do
      reader = insert(:account, role: build(:role, permissions: ["courses.read"]))
      course = insert(:course)
      section = insert(:section, course: course)
      insert(:block, section: section)

      assert {:error, :forbidden} = TestRuns.start(reader, course.id, section.id)
    end

    test "rejects a course the instructor can't even see" do
      outsider = insert(:account, role: build(:role, permissions: []))
      course = insert(:course)
      section = insert(:section, course: course)
      insert(:block, section: section)

      assert {:error, :not_found} = TestRuns.start(outsider, course.id, section.id)
    end

    test "rejects a section that isn't part of the course's playable content", %{
      instructor: instructor
    } do
      course = insert(:course)

      assert {:error, :forbidden} = TestRuns.start(instructor, course.id, Ecto.UUID.generate())
    end

    test "redirects a collapsed folder section (no blocks of its own) to its first playable subsection",
         %{instructor: instructor} do
      course = insert(:course)
      folder = insert(:section, course: course)
      lesson = insert(:section, course: course, parent_id: folder.id)
      insert(:block, section: lesson)

      assert {:ok, %TestRunSession{} = session} = TestRuns.start(instructor, course.id, folder.id)

      assert session.section_id == lesson.id
    end

    test "rejects a folder section whose subsections are all empty too", %{
      instructor: instructor
    } do
      course = insert(:course)
      folder = insert(:section, course: course)
      insert(:section, course: course, parent_id: folder.id)

      assert {:error, :section_not_playable} = TestRuns.start(instructor, course.id, folder.id)
    end

    test "seeds prior gate blocks as completed and unlocks the target section for a fresh ephemeral account",
         %{instructor: instructor} do
      course = insert(:course)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      gate_block = insert(:block, section: s1, completion_rule: %CompletionRule{type: :button})
      insert(:block, section: s2)

      assert {:ok, %TestRunSession{} = session} = TestRuns.start(instructor, course.id, s2.id)

      assert session.course_id == course.id
      assert session.section_id == s2.id
      assert session.instructor_account_id == instructor.id
      assert session.status == :active
      assert DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt

      account = Repo.get!(Account, session.ephemeral_account_id)
      assert account.status == :active
      assert String.starts_with?(account.login, "__test_run_")

      assert Repo.get_by(BlockProgress,
               account_id: account.id,
               block_id: gate_block.id,
               status: :completed
             )

      accessible =
        Athena.Learning.Progress.accessible_section_ids(account, course.id, [s1, s2])

      assert s2.id in accessible
    end

    test "does not broadcast :block_completed while seeding prior gate blocks (no fake gamification credit)",
         %{instructor: instructor} do
      course = insert(:course)
      s1 = insert(:section, course: course)
      s2 = insert(:section, course: course)

      gate_block = insert(:block, section: s1, completion_rule: %CompletionRule{type: :button})
      insert(:block, section: s2)

      Phoenix.PubSub.subscribe(Athena.PubSub, "learning_events")

      assert {:ok, session} = TestRuns.start(instructor, course.id, s2.id)
      ephemeral_account_id = session.ephemeral_account_id
      gate_block_id = gate_block.id

      # Pinned to this test's own ephemeral account/block so a broadcast from
      # an unrelated, concurrently-running async test (same global PubSub
      # topic) can't produce a false failure here.
      refute_received {:block_completed,
                       %{account_id: ^ephemeral_account_id, block_id: ^gate_block_id}}
    end

    test "reuses a single shared 'Test Run Student' role across sessions", %{
      instructor: instructor
    } do
      course = insert(:course)
      section = insert(:section, course: course)
      insert(:block, section: section)

      assert {:ok, session1} = TestRuns.start(instructor, course.id, section.id)
      assert {:ok, session2} = TestRuns.start(instructor, course.id, section.id)

      account1 = Repo.get!(Account, session1.ephemeral_account_id)
      account2 = Repo.get!(Account, session2.ephemeral_account_id)

      assert account1.role_id == account2.role_id
      assert Repo.aggregate(Role, :count) == 2
    end
  end

  describe "cleanup/1" do
    test "purges the ephemeral account and every trace of its activity, and marks the session cleaned up",
         %{instructor: instructor} do
      course = insert(:course)
      section = insert(:section, course: course)
      block = insert(:block, section: section)

      assert {:ok, session} = TestRuns.start(instructor, course.id, section.id)
      account_id = session.ephemeral_account_id

      insert(:block_progress, account_id: account_id, block_id: block.id)
      insert(:submission, account_id: account_id, block_id: block.id)
      insert(:enrollment, account_id: account_id, course_id: course.id, cohort_id: nil)
      insert(:xp_event, account_id: account_id)
      insert(:account_stats, account_id: account_id)

      assert :ok = TestRuns.cleanup(session)

      refute Repo.get(Account, account_id)
      assert Repo.get_by(BlockProgress, account_id: account_id) == nil
      assert Repo.get_by(Submission, account_id: account_id) == nil
      assert Repo.get_by(Enrollment, account_id: account_id) == nil
      assert Repo.get_by(Athena.Gamification.XpEvent, account_id: account_id) == nil
      assert Repo.get_by(Athena.Gamification.AccountStats, account_id: account_id) == nil

      reloaded_session = Repo.get!(TestRunSession, session.id)
      assert reloaded_session.status == :cleaned_up
    end

    test "is idempotent", %{instructor: instructor} do
      course = insert(:course)
      section = insert(:section, course: course)
      insert(:block, section: section)

      assert {:ok, session} = TestRuns.start(instructor, course.id, section.id)
      assert :ok = TestRuns.cleanup(session)
      assert :ok = TestRuns.cleanup(%{session | status: :active})
    end
  end

  describe "sweep_expired/0" do
    test "cleans up only sessions past their expires_at", %{instructor: instructor} do
      course = insert(:course)
      section = insert(:section, course: course)
      insert(:block, section: section)

      assert {:ok, fresh_session} = TestRuns.start(instructor, course.id, section.id)
      assert {:ok, expired_session} = TestRuns.start(instructor, course.id, section.id)

      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      expired_session
      |> TestRunSession.changeset(%{expires_at: expired_at})
      |> Repo.update!()

      assert TestRuns.sweep_expired() == 1

      assert Repo.get!(TestRunSession, fresh_session.id).status == :active
      assert Repo.get!(TestRunSession, expired_session.id).status == :cleaned_up
      refute Repo.get(Account, expired_session.ephemeral_account_id)
      assert Repo.get(Account, fresh_session.ephemeral_account_id)
    end
  end
end
