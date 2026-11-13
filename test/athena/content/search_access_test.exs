defmodule Athena.Content.SearchAccessTest do
  use Athena.DataCase, async: true

  import Athena.Factory
  import Ecto.Query
  alias Athena.{Content, Learning, Repo}
  alias Athena.Content.{AccessRules, Block, CompletionRule, TextExtractor}

  setup do
    user = insert(:account, role: insert(:role, permissions: []))
    %{user: user}
  end

  test "academic cohort progress remains personal and overrides apply to its members", %{
    user: user
  } do
    cohort = insert(:cohort, type: :academic)
    course = insert(:course)
    insert(:cohort_membership, cohort_id: cohort.id, account_id: user.id)
    insert(:enrollment, course_id: course.id, cohort_id: cohort.id, account_id: nil)
    section = insert(:section, course: course)

    gate =
      insert(:block, section: section, order: 1, completion_rule: %CompletionRule{type: :button})

    target =
      insert(:block, section: section, order: 2, search_text: "needle", visibility: :hidden)

    insert(:cohort_schedule,
      cohort_id: cohort.id,
      course_id: course.id,
      resource_type: :block,
      resource_id: target.id,
      visibility: :enrolled
    )

    Learning.mark_completed(user.id, gate.id, cohort.id)
    assert {:ok, %{items: []}} = Content.search_blocks(user, "needle")
    Learning.mark_completed(user.id, gate.id)
    assert {:ok, %{items: [%{block_id: id}]}} = Content.search_blocks(user, "needle")
    assert id == target.id

    stranger = insert(:account)
    insert(:enrollment, course_id: course.id, account_id: stranger.id)
    Learning.mark_completed(stranger.id, gate.id)
    assert {:ok, %{items: []}} = Content.search_blocks(stranger, "needle")
  end

  test "team completion unlocks all teammates but personal completion does not", %{user: user} do
    team = insert(:cohort, type: :team)
    course = insert(:course, type: :competition)
    insert(:cohort_membership, cohort_id: team.id, account_id: user.id)
    insert(:enrollment, course_id: course.id, cohort_id: team.id, account_id: nil)
    section = insert(:section, course: course)

    gate =
      insert(:block, section: section, order: 1, completion_rule: %CompletionRule{type: :button})

    target = insert(:block, section: section, order: 2, search_text: "needle")
    Learning.mark_completed(user.id, gate.id)
    assert {:ok, %{items: []}} = Content.search_blocks(user, "needle")
    Learning.mark_completed(insert(:account).id, gate.id, team.id)
    assert {:ok, %{items: [%{block_id: id}]}} = Content.search_blocks(user, "needle")
    assert id == target.id
  end

  test "team finished submissions are effective without writing completion rows", %{user: user} do
    team = insert(:cohort, type: :team)
    course = insert(:course, type: :competition)
    insert(:cohort_membership, cohort_id: team.id, account_id: user.id)
    insert(:enrollment, course_id: course.id, cohort_id: team.id, account_id: nil)
    section = insert(:section, course: course)

    gate =
      insert(:block,
        section: section,
        order: 1,
        completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 80}
      )

    insert(:block, section: section, order: 2, search_text: "needle")

    submission =
      insert(:submission,
        block_id: gate.id,
        account_id: insert(:account).id,
        cohort_id: team.id,
        status: :pending,
        score: 100
      )

    assert {:ok, %{items: []}} = Content.search_blocks(user, "needle")
    submission |> Ecto.Changeset.change(status: :graded) |> Repo.update!()
    assert {:ok, %{items: [_]}} = Content.search_blocks(user, "needle")
    refute Repo.exists?(from p in Athena.Learning.BlockProgress, where: p.block_id == ^gate.id)
  end

  test "section reset and schedule overrides share the player rules", %{user: user} do
    group = insert(:cohort, type: :academic)
    course = insert(:course)
    insert(:cohort_membership, account_id: user.id, cohort_id: group.id)
    insert(:enrollment, course_id: course.id, cohort_id: group.id, account_id: nil)
    first = insert(:section, course: course, order: 1)
    insert(:block, section: first, completion_rule: %CompletionRule{type: :button})

    second =
      insert(:section,
        course: course,
        order: 2,
        visibility: :restricted,
        access_rules: %AccessRules{reset_waterline: true}
      )

    target = insert(:block, section: second, search_text: "needle", visibility: :inherit)

    schedule =
      insert(:cohort_schedule,
        cohort_id: group.id,
        course_id: course.id,
        resource_type: :section,
        resource_id: second.id,
        visibility: :restricted,
        unlock_at: DateTime.add(DateTime.utc_now(:second), 3600)
      )

    assert {:ok, %{items: []}} = Content.search_blocks(user, "needle")

    schedule
    |> Ecto.Changeset.change(unlock_at: DateTime.add(DateTime.utc_now(:second), -3600))
    |> Repo.update!()

    assert {:ok, %{items: [%{block_id: id}]}} = Content.search_blocks(user, "needle")
    assert id == target.id

    schedule
    |> Ecto.Changeset.change(lock_at: DateTime.add(DateTime.utc_now(:second), -1))
    |> Repo.update!()

    assert {:ok, %{items: [], has_more?: false, next_cursor: nil}} =
             Content.search_blocks(user, "needle")
  end

  test "excluded fields never become searchable or snippets", %{user: user} do
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)

    doc = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "visiblecondition"}]}
      ]
    }

    question = %Block{
      type: :quiz_question,
      content: %{
        "body" => doc,
        "explanation" => doc,
        "options" => [%{"text" => "secretanswer"}],
        "answer" => "secretanswer"
      }
    }

    insert(:block,
      section: section,
      type: question.type,
      content: question.content,
      search_text: TextExtractor.extract(question)
    )

    protected = %{question | content: Map.put(question.content, "render_prompt_as_image", true)}

    insert(:block,
      section: section,
      type: protected.type,
      content: protected.content,
      search_text: TextExtractor.extract(protected)
    )

    assert {:ok, %{items: []}} = Content.search_blocks(user, "secretanswer")
    assert {:ok, %{items: [_]}} = Content.search_blocks(user, "visiblecondition")
  end

  test "a forged position and stale access never authorize a foreign block", %{user: user} do
    course = insert(:course)
    section = insert(:section, course: course)
    block = insert(:block, section: section, search_text: "needle")
    cursor = %{query: "needle", block_id: block.id, exact?: true, rank: 1.0}
    assert {:ok, %{items: []}} = Content.search_blocks(user, "needle", cursor: cursor)

    assert {:error, :invalid_cursor} =
             Content.search_blocks(user, "needle", cursor: %{cursor | rank: 2.0})

    assert {:error, :forbidden} = Content.resolve_block_permalink(user, block.id)
  end
end
