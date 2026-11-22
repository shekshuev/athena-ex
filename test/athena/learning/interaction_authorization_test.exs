defmodule Athena.Learning.InteractionAuthorizationTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Learning
  alias Athena.Content.{AccessRules, CompletionRule}
  alias Athena.Learning.{BlockProgress, Submission}

  setup do
    user = insert(:account)
    course = insert(:course)
    section = insert(:section, course: course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    %{user: user, course: course, section: section}
  end

  describe "button completion" do
    test "only the current visible button can complete and repetition is idempotent", ctx do
      first = button(ctx.section, 10)
      second = button(ctx.section, 20)

      assert {:error, :forbidden} = complete(ctx, second.id)
      refute Repo.exists?(BlockProgress)

      assert {:ok, progress} = complete(ctx, first.id)
      assert {:ok, _} = complete(ctx, first.id)
      assert Repo.get_by!(BlockProgress, block_id: first.id).id == progress.id
      assert Repo.aggregate(BlockProgress, :count) == 1
      assert {:ok, _} = complete(ctx, second.id)
    end

    test "rejects foreign lessons and courses, missing IDs and non-button blocks", ctx do
      own = button(ctx.section, 10)
      foreign_lesson = insert(:section, course: ctx.course)
      foreign_course = insert(:section)
      lesson_gate = button(foreign_lesson, 10)
      course_gate = button(foreign_course, 10)
      ordinary = insert(:block, section: ctx.section, order: 5)
      exam = insert(:block, section: ctx.section, type: :quiz_exam, order: 6)

      auto_gate =
        insert(:block,
          section: ctx.section,
          order: 30,
          completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 100}
        )

      Phoenix.PubSub.subscribe(Athena.PubSub, "learning_events")

      for id <- [
            lesson_gate.id,
            course_gate.id,
            ordinary.id,
            exam.id,
            auto_gate.id,
            Ecto.UUID.generate(),
            "invalid",
            nil
          ] do
        assert {:error, :forbidden} = complete(ctx, id)
      end

      refute Repo.exists?(BlockProgress)
      refute Repo.exists?(Submission)
      account_id = ctx.user.id
      refute_received {:block_completed, %{account_id: ^account_id}}
      assert Map.has_key?(Learning.course_block_access(ctx.user, ctx.course.id), own.id)
    end

    test "rechecks enrollment and persisted policy after the page was opened", ctx do
      gate = button(ctx.section, 10)
      Repo.update_all(Athena.Learning.Enrollment, set: [status: :dropped])
      assert {:error, :forbidden} = complete(ctx, gate.id)
      refute Repo.exists?(BlockProgress)
    end

    test "assessments and surveys cannot be completed by a button rule", ctx do
      for type <- [:quiz_exam, :ticket_exam, :survey] do
        block =
          insert(:block,
            section: ctx.section,
            type: type,
            completion_rule: %CompletionRule{type: :button}
          )

        assert {:error, :forbidden} = complete(ctx, block.id)
        Repo.delete!(block)
      end

      refute Repo.exists?(BlockProgress)
    end

    test "rejects hidden, scheduled and readonly gates", ctx do
      hidden =
        insert(:block,
          section: ctx.section,
          visibility: :hidden,
          completion_rule: %CompletionRule{type: :button}
        )

      future =
        insert(:block,
          section: ctx.section,
          visibility: :restricted,
          access_rules: %AccessRules{unlock_at: DateTime.add(DateTime.utc_now(), 3600)},
          completion_rule: %CompletionRule{type: :button}
        )

      readonly =
        insert(:block,
          section: ctx.section,
          interaction_mode: :readonly,
          completion_rule: %CompletionRule{type: :button}
        )

      for block <- [hidden, future, readonly] do
        assert {:error, :forbidden} = complete(ctx, block.id)
      end

      refute Repo.exists?(BlockProgress)
    end

    test "uses only the enrolled team for shared progress", ctx do
      team = enroll_team(ctx)
      gate = button(ctx.section, 10)
      assert {:ok, progress} = complete(ctx, gate.id)
      assert progress.cohort_id == team.id
      teammate = insert(:account)
      insert(:cohort_membership, account_id: teammate.id, cohort_id: team.id)
      assert {:ok, _} = complete(%{ctx | user: teammate}, gate.id)
      assert Repo.get_by!(BlockProgress, block_id: gate.id).id == progress.id
      assert Repo.aggregate(BlockProgress, :count) == 1
    end

    test "unknown and deleted blocks are rejected through the Content API", ctx do
      Phoenix.PubSub.subscribe(Athena.PubSub, "learning_events")

      for id <- [Ecto.UUID.generate(), "invalid", nil] do
        assert {:error, :not_found} = Learning.mark_completed(ctx.user.id, id)
      end

      gate = button(ctx.section, 10)
      Repo.delete!(gate)
      assert {:error, :not_found} = Learning.mark_completed(ctx.user.id, gate.id)
      refute Repo.exists?(BlockProgress)
      account_id = ctx.user.id
      refute_received {:block_completed, %{account_id: ^account_id}}
    end

    test "deleting Content does not cascade into Learning history", ctx do
      gate = button(ctx.section, 10)
      assert {:ok, progress} = complete(ctx, gate.id)
      Repo.delete!(gate)

      assert Repo.get!(BlockProgress, progress.id).block_id == gate.id
      assert {:error, :not_found} = Learning.mark_completed(ctx.user.id, gate.id)
    end
  end

  describe "exam authorization" do
    test "honors section visibility and schedule, not just the exam's own policy", ctx do
      section = insert(:section, course: ctx.course, visibility: :hidden)
      exam = insert(:block, section: section, type: :quiz_exam)
      assert {:error, :forbidden} = attempt(ctx, exam)

      section
      |> Ecto.Changeset.change(visibility: :restricted)
      |> Ecto.Changeset.put_embed(
        :access_rules,
        %AccessRules{unlock_at: DateTime.add(DateTime.utc_now(), 3600)}
      )
      |> Repo.update!()

      assert {:error, :forbidden} = attempt(ctx, exam)
      refute Repo.exists?(Submission)
    end

    test "denies missing enrollment, mismatched course, invalid ID and wrong type", ctx do
      exam = insert(:block, section: ctx.section, type: :quiz_exam)
      outsider = insert(:account)
      other_course = insert(:course)
      insert(:enrollment, account_id: ctx.user.id, course_id: other_course.id)
      ordinary = insert(:block, section: ctx.section)

      assert {:error, :forbidden} = attempt(%{ctx | user: outsider}, exam)
      assert {:error, :forbidden} = attempt(%{ctx | course: other_course}, exam)
      assert {:error, :forbidden} = attempt(ctx, %{exam | id: "invalid"})
      assert {:error, :forbidden} = attempt(ctx, %{exam | id: Ecto.UUID.generate()})
      assert {:error, :forbidden} = attempt(ctx, ordinary)
      assert {:error, :forbidden} = attempt(ctx, exam, :ticket_exam)
      refute Repo.exists?(Submission)
    end

    test "denies hidden, readonly and future exams without creating attempts", ctx do
      for attrs <- [
            [visibility: :hidden],
            [interaction_mode: :readonly],
            [
              visibility: :restricted,
              access_rules: %AccessRules{unlock_at: DateTime.add(DateTime.utc_now(), 3600)}
            ]
          ] do
        exam = insert(:block, Keyword.merge([section: ctx.section, type: :quiz_exam], attrs))
        assert {:error, :forbidden} = attempt(ctx, exam)
      end

      refute Repo.exists?(Submission)
    end

    test "denies block and lesson waterline bypasses without healing progress", ctx do
      button(ctx.section, 10)
      exam = insert(:block, section: ctx.section, type: :quiz_exam, order: 20)
      later = insert(:section, course: ctx.course, order: 10)
      later_exam = insert(:block, section: later, type: :quiz_exam)
      assert {:error, :forbidden} = attempt(ctx, exam)
      assert {:error, :forbidden} = attempt(ctx, later_exam)
      refute Repo.exists?(Submission)
      refute Repo.exists?(BlockProgress)
    end

    test "uses persisted config, resumes an allowed attempt and refuses revoked access", ctx do
      exam =
        insert(:block,
          section: ctx.section,
          type: :quiz_exam,
          content: %{"time_limit" => 12, "count" => 1}
        )

      assert {:ok, submission} = attempt(ctx, exam)
      assert submission.cohort_id == nil
      assert DateTime.diff(submission.expires_at, submission.inserted_at) in 719..721
      assert {:ok, resumed} = attempt(ctx, exam)
      assert resumed.id == submission.id
      before_denied = Repo.get!(Submission, submission.id)

      Repo.update_all(Athena.Learning.Enrollment, set: [status: :dropped])
      assert {:error, :forbidden} = attempt(ctx, exam)
      assert Repo.get!(Submission, submission.id) == before_denied
    end

    test "derives the team from enrollment and preserves the team's shared attempt", ctx do
      team = enroll_team(ctx)
      exam = insert(:block, section: ctx.section, type: :ticket_exam, content: %{"slots" => []})
      assert {:ok, submission} = attempt(ctx, exam, :ticket_exam)
      assert submission.cohort_id == team.id
      teammate = insert(:account)
      insert(:cohort_membership, account_id: teammate.id, cohort_id: team.id)
      assert {:taken_by_teammate, held} = attempt(%{ctx | user: teammate}, exam, :ticket_exam)
      assert held.id == submission.id
      assert Repo.aggregate(Submission, :count) == 1
    end
  end

  test "preview bypass is scoped to a live persisted session and its course", ctx do
    instructor =
      insert(:account, role: insert(:role, permissions: ["courses.read", "courses.update"]))

    course = insert(:course, owner_id: instructor.id, status: :draft)
    section = insert(:section, course: course, visibility: :hidden)
    gate = button(section, 10)
    exam = insert(:block, section: section, type: :quiz_exam, order: 20)
    assert {:ok, session} = Learning.start_test_run(instructor, course.id, section.id)
    user = Repo.get!(Athena.Identity.Account, session.ephemeral_account_id)
    preview = %{user: user, course: course, section: section}

    assert {:ok, _} = complete(preview, gate.id)
    assert {:ok, _} = attempt(preview, exam)
    foreign_exam = insert(:block, section: ctx.section, type: :quiz_exam)
    assert {:error, :forbidden} = attempt(%{preview | course: ctx.course}, foreign_exam)

    session
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1))
    |> Repo.update!()

    assert {:error, :forbidden} = attempt(preview, exam)
    assert {:error, :forbidden} = complete(preview, gate.id)
    assert :ok = Learning.cleanup_test_run(session)
    assert {:error, :forbidden} = attempt(preview, exam)
  end

  defp button(section, order) do
    insert(:block,
      section: section,
      order: order,
      completion_rule: %CompletionRule{type: :button}
    )
  end

  defp complete(ctx, block_id),
    do: Learning.complete_button_gate(ctx.user, ctx.course.id, ctx.section.id, block_id)

  # Deliberately pass forged cohort/config/limit values: the public operation
  # must resolve those from persisted course membership and the block itself.
  defp attempt(ctx, block, type \\ :quiz_exam),
    do:
      Learning.get_or_create_exam_attempt(
        ctx.course.id,
        ctx.user.id,
        block.id,
        type,
        Ecto.UUID.generate(),
        999_999,
        %{"count" => 999}
      )

  defp enroll_team(ctx) do
    team = insert(:cohort, type: :team)
    insert(:enrollment, cohort_id: team.id, course_id: ctx.course.id)
    insert(:cohort_membership, account_id: ctx.user.id, cohort_id: team.id)
    team
  end
end
