defmodule Athena.Media.AccessTest do
  use Athena.DataCase, async: true

  import Athena.Factory
  alias Athena.{Content, Learning, Media}
  alias Athena.Content.CompletionRule

  setup do
    user = insert(:account, role: insert(:role, permissions: []))
    course = insert(:course)
    section = insert(:section, course: course)
    insert(:enrollment, account_id: user.id, course_id: course.id)
    %{user: user, course: course, section: section}
  end

  test "unknown keys, inactive accounts and another user's pending uploads are denied", ctx do
    for key <- [
          "probe/attack.html",
          "courses/#{ctx.course.id}/unreferenced.png",
          "submissions/#{Ecto.UUID.generate()}/x.png",
          "../secret.txt"
        ] do
      assert {:error, :forbidden} = Media.download_url(ctx.user, key)
    end

    own = "submissions/#{ctx.user.id}/#{ctx.course.id}/new.png"
    assert {:ok, _} = Media.download_url(ctx.user, own)
    assert {:error, :forbidden} = Media.download_url(%{ctx.user | status: :blocked}, own)
  end

  test "course files follow enrollment, block visibility and gates", ctx do
    key = "courses/#{ctx.course.id}/diagram.png"

    gate =
      insert(:block,
        section: ctx.section,
        order: 10,
        completion_rule: %CompletionRule{type: :button}
      )

    insert(:block, section: ctx.section, order: 20, content: %{"url" => "/media/#{key}"})
    assert {:error, :forbidden} = Media.download_url(ctx.user, key)

    assert {:ok, _} =
             Learning.complete_button_gate(ctx.user, ctx.course.id, ctx.section.id, gate.id)

    assert {:ok, _} = Media.download_url(ctx.user, key)
    Repo.update_all(Learning.Enrollment, set: [status: :dropped])
    assert {:error, :forbidden} = Media.download_url(ctx.user, key)
  end

  test "library files follow template visibility and sharing" do
    reader =
      insert(:account,
        role:
          insert(:role,
            permissions: ["library.read"],
            policies: %{"library.read" => ["own_only"]}
          )
      )

    key = "library/#{Ecto.UUID.generate()}/question.png"
    block = insert(:library_block, is_public: false, content: %{"url" => "/media/#{key}"})
    assert {:error, :forbidden} = Media.download_url(reader, key)
    insert(:library_block_share, library_block: block, account_id: reader.id, role: :reader)
    assert {:ok, _} = Media.download_url(reader, key)
  end

  test "legacy unregistered submission files remain available to their author and grader", ctx do
    key = "courses/#{ctx.course.id}/legacy-answer.pdf"
    block = insert(:block, section: ctx.section, type: :file_assignment)

    insert(:submission,
      account_id: ctx.user.id,
      block_id: block.id,
      content: %{"file_urls" => ["/media/#{key}"]}
    )

    grader = insert(:account, role: insert(:role, permissions: ["grading.read"]))
    stranger = insert(:account, role: insert(:role, permissions: []))
    assert {:ok, _} = Media.download_url(ctx.user, key)
    assert {:ok, _} = Media.download_url(grader, key)
    assert {:error, :forbidden} = Media.download_url(stranger, key)
  end

  test "pasting a private Content key into an answer does not grant access", ctx do
    key = "library/#{Ecto.UUID.generate()}/private-bank.png"
    insert(:library_block, content: %{"url" => "/media/#{key}"}, is_public: false)
    block = insert(:block, section: ctx.section, type: :file_assignment)

    insert(:submission,
      account_id: ctx.user.id,
      block_id: block.id,
      content: %{"file_urls" => ["/media/#{key}"]}
    )

    assert {:error, :forbidden} = Media.download_url(ctx.user, key)
  end

  test "server-generated exam question images are accessible without library permission", ctx do
    key = "library/#{Ecto.UUID.generate()}/private-bank.png"
    insert(:library_block, content: %{"url" => "/media/#{key}"}, is_public: false)
    block = insert(:block, section: ctx.section, type: :quiz_exam)

    insert(:submission,
      account_id: ctx.user.id,
      block_id: block.id,
      status: :pending,
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
      content: %{
        "type" => "quiz_exam",
        "questions" => [%{"content" => %{"url" => "/media/#{key}"}}]
      }
    )

    assert {:ok, _} = Media.download_url(ctx.user, key)
    Repo.update_all(Learning.Enrollment, set: [status: :dropped])
    assert {:error, :forbidden} = Media.download_url(ctx.user, key)
  end

  test "another author's submission key cannot be laundered through one's own answer", ctx do
    author = insert(:account)
    key = "submissions/#{author.id}/#{ctx.course.id}/private.png"
    block = insert(:block, section: ctx.section)

    insert(:submission,
      account_id: ctx.user.id,
      block_id: block.id,
      content: %{"file_urls" => ["/media/#{key}"]}
    )

    assert {:error, :forbidden} = Media.download_url(ctx.user, key)
  end

  test "exam question images still follow enrollment when the source template is gone", ctx do
    key = "library/#{Ecto.UUID.generate()}/removed-question.png"
    block = insert(:block, section: ctx.section, type: :quiz_exam)

    insert(:submission,
      account_id: ctx.user.id,
      block_id: block.id,
      status: :pending,
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
      content: %{
        "type" => "quiz_exam",
        "questions" => [%{"content" => %{"url" => "/media/#{key}"}}]
      }
    )

    assert {:ok, _} = Media.download_url(ctx.user, key)
    Repo.update_all(Learning.Enrollment, set: [status: :dropped])
    assert {:error, :forbidden} = Media.download_url(ctx.user, key)
  end

  test "new submission slots require course access and use an owner namespace", ctx do
    assert {:ok, meta} = Media.prepare_submission_upload(ctx.user, ctx.course.id, "answer.pdf")
    assert String.starts_with?(meta.key, "submissions/#{ctx.user.id}/#{ctx.course.id}/")
    assert meta.content_type == "application/octet-stream"

    assert {:error, :unsupported_file_type} =
             Media.prepare_submission_upload(ctx.user, ctx.course.id, "attack.html")

    assert {:error, :forbidden} =
             Media.prepare_submission_upload(ctx.user, Ecto.UUID.generate(), "answer.pdf")

    assert {:error, :forbidden} = Content.prepare_media_upload(ctx.user, "library", "image.png")
  end

  test "a team member can read an attachment uploaded by a teammate and submitted by them", ctx do
    teammate = insert(:account)
    stranger = insert(:account, role: insert(:role, permissions: []))
    team = insert(:cohort, type: :team)

    for user <- [ctx.user, teammate],
        do: insert(:cohort_membership, account_id: user.id, cohort_id: team.id)

    insert(:enrollment, cohort_id: team.id, course_id: ctx.course.id)
    block = insert(:block, section: ctx.section, type: :file_assignment)
    key = "submissions/#{teammate.id}/#{ctx.course.id}/team.pdf"

    insert(:submission,
      account_id: ctx.user.id,
      cohort_id: team.id,
      block_id: block.id,
      content: %{"file_urls" => ["/media/#{key}"]}
    )

    assert {:ok, _} = Media.download_url(ctx.user, key)
    assert {:ok, _} = Media.download_url(teammate, key)
    assert {:error, :forbidden} = Media.download_url(stranger, key)
  end

  test "a legacy file cannot be claimed by pasting another student's attachment into an answer",
       ctx do
    author = insert(:account)
    key = "courses/#{ctx.course.id}/legacy-private.pdf"
    block = insert(:block, section: ctx.section, type: :file_assignment)

    insert(:submission,
      account_id: author.id,
      block_id: block.id,
      content: %{"file_urls" => ["/media/#{key}"]}
    )

    assert {:error, :forbidden} = Media.download_url(ctx.user, key)

    insert(:submission,
      account_id: ctx.user.id,
      block_id: block.id,
      content: %{"file_urls" => ["/media/#{key}"]}
    )

    assert {:error, :forbidden} = Media.download_url(ctx.user, key)
  end
end
