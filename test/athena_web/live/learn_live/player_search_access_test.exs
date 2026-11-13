defmodule AthenaWeb.LearnLive.PlayerSearchAccessTest do
  use AthenaWeb.ConnCase, async: true

  import Athena.Factory
  import Phoenix.LiveViewTest
  alias Athena.{Content, Learning, Repo}
  alias Athena.Content.CompletionRule

  test "a gate added after search hides the linked block in a freshly mounted player", %{
    conn: conn
  } do
    user = insert(:account, role: insert(:role, permissions: []))
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    section = insert(:section, course: course)
    gate = insert(:block, section: section, order: 1)
    target = insert(:block, section: section, order: 2, search_text: "needle")
    assert {:ok, %{items: [%{block_id: id}]}} = Content.search_blocks(user, "needle")
    assert id == target.id

    gate
    |> Ecto.Changeset.change(completion_rule: %CompletionRule{type: :button})
    |> Repo.update!()

    assert {:error, :not_found} = Content.resolve_block_permalink(user, target.id)
    assert {:ok, %{items: []}} = Content.search_blocks(user, "needle")

    conn = init_test_session(conn, %{"account_id" => user.id})

    {:ok, view, _html} =
      live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}?block=#{target.id}")

    assert has_element?(view, "#block-wrapper-#{gate.id}")
    refute has_element?(view, "#block-wrapper-#{target.id}")

    Learning.mark_completed(user.id, gate.id)

    {:ok, unlocked, _html} =
      live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}?block=#{target.id}")

    assert has_element?(unlocked, "#block-wrapper-#{target.id}")
  end
end
