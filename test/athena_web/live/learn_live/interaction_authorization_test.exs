defmodule AthenaWeb.LearnLive.InteractionAuthorizationTest do
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Repo
  alias Athena.Content.{AccessRules, CompletionRule}
  alias Athena.Learning.{BlockProgress, Submission}

  setup %{conn: conn} do
    user = insert(:account)
    course = insert(:course)
    section = insert(:section, course: course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    conn = init_test_session(conn, %{"account_id" => user.id})
    %{conn: conn, user: user, course: course, section: section}
  end

  test "crafted completion events cannot unlock hidden content or complete an exam", ctx do
    gate =
      insert(:block,
        section: ctx.section,
        order: 10,
        completion_rule: %CompletionRule{type: :button}
      )

    behind =
      insert(:block,
        section: ctx.section,
        order: 20,
        completion_rule: %CompletionRule{type: :button}
      )

    exam = insert(:block, section: ctx.section, order: 30, type: :quiz_exam)
    other_lesson = insert(:section, course: ctx.course, order: 10)

    foreign =
      insert(:block,
        section: other_lesson,
        completion_rule: %CompletionRule{type: :button}
      )

    {:ok, view, _} = live(ctx.conn, ~p"/learn/courses/#{ctx.course.id}/play/#{ctx.section.id}")
    assert has_element?(view, "#block-wrapper-#{gate.id}")
    refute has_element?(view, "#block-wrapper-#{behind.id}")
    Phoenix.PubSub.subscribe(Athena.PubSub, "learning_events")

    for id <- [behind.id, exam.id, foreign.id, Ecto.UUID.generate(), "invalid"] do
      render_click(view, "complete_gate", %{"block-id" => id})
      refute Repo.exists?(BlockProgress)
      refute has_element?(view, "#block-wrapper-#{behind.id}")
    end

    account_id = ctx.user.id
    refute_received {:block_completed, %{account_id: ^account_id}}
    render_click(view, "complete_gate", %{"block-id" => gate.id})
    assert has_element?(view, "#block-wrapper-#{behind.id}")
    assert Repo.get_by!(BlockProgress, account_id: ctx.user.id, block_id: gate.id)
  end

  test "a stale player cannot complete gates after enrollment is revoked", ctx do
    gate = insert(:block, section: ctx.section, completion_rule: %CompletionRule{type: :button})
    {:ok, view, _} = live(ctx.conn, ~p"/learn/courses/#{ctx.course.id}/play/#{ctx.section.id}")
    Repo.update_all(Athena.Learning.Enrollment, set: [status: :dropped])
    render_click(view, "complete_gate", %{"block-id" => gate.id})
    refute Repo.exists?(BlockProgress)
  end

  test "a stale player cannot complete a gate hidden after mount", ctx do
    gate = insert(:block, section: ctx.section, completion_rule: %CompletionRule{type: :button})
    {:ok, view, _} = live(ctx.conn, ~p"/learn/courses/#{ctx.course.id}/play/#{ctx.section.id}")
    gate |> Ecto.Changeset.change(visibility: :hidden) |> Repo.update!()
    render_click(view, "complete_gate", %{"block-id" => gate.id})
    refute Repo.exists?(BlockProgress)
  end

  for {type, route} <- [quiz_exam: "exam", ticket_exam: "ticket"] do
    @type_under_test type
    @route_under_test route

    test "#{route}: denies foreign course, missing enrollment, wrong type and invalid IDs", ctx do
      block = insert(:block, section: ctx.section, type: @type_under_test)
      other_course = insert(:course)
      insert(:enrollment, account_id: ctx.user.id, course_id: other_course.id)
      outsider = insert(:account)
      other_conn = init_test_session(ctx.conn, %{"account_id" => outsider.id})
      wrong_type = insert(:block, section: ctx.section, type: :text)

      for {conn, course_id, block_id} <- [
            {ctx.conn, other_course.id, block.id},
            {other_conn, ctx.course.id, block.id},
            {ctx.conn, ctx.course.id, wrong_type.id},
            {ctx.conn, ctx.course.id, "invalid"},
            {ctx.conn, ctx.course.id, Ecto.UUID.generate()}
          ] do
        assert {:error, {:live_redirect, _}} =
                 live(conn, exam_path(course_id, block_id, @route_under_test))

        refute Repo.exists?(Submission)
      end
    end

    test "#{route}: denies future and hidden exams and unmet prerequisites", ctx do
      future =
        insert(:block,
          section: ctx.section,
          type: @type_under_test,
          visibility: :restricted,
          access_rules: %AccessRules{unlock_at: DateTime.add(DateTime.utc_now(), 3600)},
          order: 1
        )

      hidden =
        insert(:block,
          section: ctx.section,
          type: @type_under_test,
          visibility: :hidden,
          order: 2
        )

      insert(:block,
        section: ctx.section,
        order: 10,
        completion_rule: %CompletionRule{type: :button}
      )

      locked = insert(:block, section: ctx.section, type: @type_under_test, order: 20)

      for block <- [future, hidden, locked] do
        assert {:error, {:live_redirect, _}} =
                 live(ctx.conn, exam_path(ctx.course.id, block.id, @route_under_test))

        refute Repo.exists?(Submission)
      end
    end

    test "#{route}: valid attempts resume but revoked enrollment cannot reopen the paper", ctx do
      block = insert(:block, section: ctx.section, type: @type_under_test)
      url = exam_path(ctx.course.id, block.id, @route_under_test)
      {:ok, first, _} = live(ctx.conn, url)
      attempt = Repo.get_by!(Submission, account_id: ctx.user.id, block_id: block.id)
      assert has_element?(first, "#multi-tab-guard-#{attempt.id}")
      {:ok, _second, _} = live(ctx.conn, url)
      assert Repo.aggregate(Submission, :count) == 1
      assert Repo.get!(Submission, attempt.id).expires_at == attempt.expires_at

      Repo.update_all(Athena.Learning.Enrollment, set: [status: :dropped])
      assert {:error, {:live_redirect, _}} = live(ctx.conn, url)
      assert Repo.aggregate(Submission, :count) == 1
    end
  end

  defp exam_path(course_id, block_id, route),
    do: "/learn/courses/#{course_id}/#{route}/#{block_id}"
end
