defmodule AthenaWeb.LearnLive.DailyChallengeTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Gamification.DailyChallenges
  alias Athena.Learning.{BlockProgress, Progress}
  alias Athena.Repo

  setup %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})

    case Process.whereis(Athena.PG) do
      nil -> :pg.start_link(Athena.PG)
      _pid -> :ok
    end

    Enum.each([:db, :compiled, :script], &:pg.join(Athena.PG, {:code_runners, &1}, self()))

    on_exit(fn ->
      Enum.each([:db, :compiled, :script], &:pg.leave(Athena.PG, {:code_runners, &1}, self()))
    end)

    %{conn: conn, user: user}
  end

  defp enroll_and_complete(user, block) do
    insert(:enrollment, account_id: user.id, course_id: block.section.course_id)
    Progress.mark_completed(user.id, block.id)
  end

  describe "mount" do
    test "shows an empty state when there is no challenge today", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/daily-challenge")

      assert html =~ "No challenge available yet"
    end

    test "shows a solved state when today's challenge is already completed", %{
      conn: conn,
      user: user
    } do
      section = insert(:section)
      block = insert(:block, section: section, type: :code)
      enroll_and_complete(user, block)

      challenge = DailyChallenges.today_for(user.id)

      DailyChallenges.handle_block_completed(%{
        account_id: user.id,
        block_id: challenge.block_id,
        block_type: :code,
        cohort_id: nil
      })

      {:ok, _lv, html} = live(conn, ~p"/daily-challenge")

      assert html =~ "Solved today!"
    end

    test "renders the block for an active code challenge", %{conn: conn, user: user} do
      section = insert(:section)
      block = insert(:block, section: section, type: :code, content: %{"language" => "python3"})
      enroll_and_complete(user, block)

      {:ok, _lv, html} = live(conn, ~p"/daily-challenge")

      assert html =~ "daily-challenge-code-#{block.id}"
    end

    test "renders the block for an active quiz_question challenge", %{conn: conn, user: user} do
      section = insert(:section)

      block =
        insert(:block,
          section: section,
          type: :quiz_question,
          content: %{"question_type" => "exact_match", "correct_answer" => "42"}
        )

      enroll_and_complete(user, block)

      {:ok, _lv, html} = live(conn, ~p"/daily-challenge")

      assert html =~ "daily-challenge-quiz-#{block.id}"
    end

    test "never shows the account's original submission for this block", %{
      conn: conn,
      user: user
    } do
      section = insert(:section)
      block = insert(:block, section: section, type: :code, content: %{"language" => "python3"})
      enroll_and_complete(user, block)

      insert(:submission,
        account_id: user.id,
        block_id: block.id,
        status: :accepted,
        score: 100,
        content: %{"code" => "print('original solution')"}
      )

      {:ok, _lv, html} = live(conn, ~p"/daily-challenge")

      refute html =~ "Resubmit"
      refute html =~ "original solution"
      assert html =~ "Submit"
    end
  end

  describe "solving the challenge" do
    test "an accepted code submission (via the async result) marks the block completed", %{
      conn: conn,
      user: user
    } do
      section = insert(:section)
      block = insert(:block, section: section, type: :code, content: %{"language" => "python3"})
      enroll_and_complete(user, block)

      {:ok, lv, _html} = live(conn, ~p"/daily-challenge")

      lv
      |> form("#daily-challenge-code-#{block.id}")
      |> render_submit(%{"block_id" => block.id, "answer" => %{"code" => "print(1)"}})

      submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :accepted,
          score: 100
        )

      send(lv.pid, {:submission_updated, submission})

      assert render(lv) =~ "Solved today!"

      assert Repo.get_by(BlockProgress,
               account_id: user.id,
               block_id: block.id,
               status: :completed
             )
    end

    test "a quiz_question answered correctly marks the block completed", %{
      conn: conn,
      user: user
    } do
      section = insert(:section)

      block =
        insert(:block,
          section: section,
          type: :quiz_question,
          content: %{"question_type" => "exact_match", "correct_answer" => "42"}
        )

      enroll_and_complete(user, block)

      {:ok, lv, _html} = live(conn, ~p"/daily-challenge")

      lv
      |> form("#daily-challenge-quiz-#{block.id}", %{"answer" => "42"})
      |> render_submit()

      assert render(lv) =~ "Solved today!"

      assert Repo.get_by(BlockProgress,
               account_id: user.id,
               block_id: block.id,
               status: :completed
             )
    end

    test "a quiz_question answered incorrectly does not complete it", %{conn: conn, user: user} do
      section = insert(:section)

      block =
        insert(:block,
          section: section,
          type: :quiz_question,
          content: %{"question_type" => "exact_match", "correct_answer" => "42"}
        )

      enroll_and_complete(user, block)

      {:ok, lv, _html} = live(conn, ~p"/daily-challenge")

      html =
        lv
        |> form("#daily-challenge-quiz-#{block.id}", %{"answer" => "wrong"})
        |> render_submit()

      refute html =~ "Solved today!"
      assert html =~ "Incorrect"
    end
  end
end
