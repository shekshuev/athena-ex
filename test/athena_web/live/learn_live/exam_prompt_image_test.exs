defmodule AthenaWeb.LearnLive.ExamPromptImageTest do
  use AthenaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Content.Block
  alias Athena.Repo

  for {kind, route} <- [{:quiz_exam, "exam"}, {:ticket_exam, "ticket"}],
      question_type <- [:quiz_question, :code, :file_assignment],
      {exam_image, question_image} <- [{false, false}, {false, true}, {true, false}, {true, true}] do
    @kind kind
    @question_type question_type
    @route route
    @exam_image exam_image
    @question_image question_image

    test "#{kind} #{question_type}: exam image=#{exam_image}, question image=#{question_image}",
         %{conn: conn} do
      user = insert(:account)
      course = insert(:course)
      insert(:enrollment, account_id: user.id, course_id: course.id)
      section = insert(:section, course: course)
      block = insert(:block, section: section, type: @kind)

      {:ok, block} =
        block
        |> Block.changeset(%{
          content: Map.put(block.content, "render_prompt_as_image", @exam_image)
        })
        |> Repo.update()

      assert block.content["render_prompt_as_image"] == @exam_image

      question_id = Ecto.UUID.generate()

      body = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Question"}]}
        ]
      }

      question = %{
        "id" => question_id,
        "type" => Atom.to_string(@question_type),
        "content" => %{
          "question_type" => "exact_match",
          "body" => body,
          "render_prompt_as_image" => @question_image
        }
      }

      submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :pending,
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
          content: %{"type" => Atom.to_string(@kind), "questions" => [question]}
        )

      {:ok, view, _} =
        live(
          init_test_session(conn, %{"account_id" => user.id}),
          "/learn/courses/#{course.id}/#{@route}/#{block.id}"
        )

      assert has_element?(view, "#prompt-canvas-#{question_id}") ==
               (@exam_image or @question_image)

      assert has_element?(view, "#editor-wrapper-play-#{question_id} [phx-hook='TiptapEditor']") ==
               not (@exam_image or @question_image)

      assert Athena.Repo.get!(Athena.Learning.Submission, submission.id).content["questions"] == [
               question
             ]
    end
  end
end
