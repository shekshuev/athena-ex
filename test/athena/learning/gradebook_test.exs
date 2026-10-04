defmodule Athena.Learning.GradebookTest do
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Learning.Gradebook

  setup do
    course = insert(:course)
    section_a = insert(:section, course: course, title: "Loops", order: 10)
    section_b = insert(:section, course: course, title: "Functions", order: 20)

    theory = insert(:block, section: section_a, type: :text, order: 5)
    quiz = insert(:block, section: section_a, type: :quiz_question, order: 10)
    code = insert(:block, section: section_a, type: :code, order: 20)
    exam = insert(:block, section: section_b, type: :quiz_exam, order: 10)

    cohort = insert(:cohort, type: :academic)
    ivanov = insert(:account, login: "ivanov")
    petrova = insert(:account, login: "petrova")
    insert(:cohort_membership, account_id: ivanov.id, cohort_id: cohort.id)
    insert(:cohort_membership, account_id: petrova.id, cohort_id: cohort.id)

    %{
      course: course,
      section_a: section_a,
      theory: theory,
      quiz: quiz,
      code: code,
      exam: exam,
      cohort: cohort,
      ivanov: ivanov,
      petrova: petrova
    }
  end

  defp submit(account, block, status, score, minutes_ago, attrs \\ []) do
    at =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(-minutes_ago * 60, :second)

    insert(
      :submission,
      Keyword.merge(
        [
          account_id: account.id,
          block_id: block.id,
          status: status,
          score: score,
          inserted_at: at,
          updated_at: at
        ],
        attrs
      )
    )
  end

  describe "build/3 - structure" do
    test "columns are the gradable blocks only, in course order, numbered per section", ctx do
      gradebook = Gradebook.build(ctx.cohort, ctx.course.id)

      assert Enum.map(gradebook.columns, & &1.block.id) == [ctx.quiz.id, ctx.code.id, ctx.exam.id]
      assert Enum.map(gradebook.columns, & &1.number) == [1, 2, 1]

      assert [%{section: %{title: "Loops"}, blocks: [_, _]}, %{section: %{title: "Functions"}}] =
               gradebook.catalog
    end

    test "rows are the cohort's students, sorted by name", ctx do
      gradebook = Gradebook.build(ctx.cohort, ctx.course.id)

      assert Enum.map(gradebook.rows, & &1.id) |> Enum.sort() ==
               Enum.sort([ctx.ivanov.id, ctx.petrova.id])

      assert gradebook.rows == Enum.sort_by(gradebook.rows, &String.downcase(&1.name))
    end
  end

  describe "build/3 - which attempt is shown" do
    test "best attempt by default, with the total attempt count", ctx do
      submit(ctx.ivanov, ctx.quiz, :graded, 40, 30)
      best = submit(ctx.ivanov, ctx.quiz, :graded, 90, 20)
      submit(ctx.ivanov, ctx.quiz, :graded, 60, 10)

      %{cells: cells} = Gradebook.build(ctx.cohort, ctx.course.id)

      assert %{state: :scored, score: 90, attempts: 3, submission_id: id} =
               cells[{ctx.ivanov.id, ctx.quiz.id}]

      assert id == best.id
    end

    test "last and first attempt policies", ctx do
      submit(ctx.ivanov, ctx.quiz, :graded, 40, 30)
      submit(ctx.ivanov, ctx.quiz, :graded, 90, 20)
      submit(ctx.ivanov, ctx.quiz, :wrong_answer, 0, 10)

      assert %{score: 0} =
               Gradebook.build(ctx.cohort, ctx.course.id, %{attempt: :last}).cells[
                 {ctx.ivanov.id, ctx.quiz.id}
               ]

      assert %{score: 40} =
               Gradebook.build(ctx.cohort, ctx.course.id, %{attempt: :first}).cells[
                 {ctx.ivanov.id, ctx.quiz.id}
               ]
    end

    test "best ignores attempts still awaiting a grade, but falls back to them", ctx do
      submit(ctx.ivanov, ctx.quiz, :graded, 70, 20)
      submit(ctx.ivanov, ctx.quiz, :needs_review, 0, 10)
      submit(ctx.petrova, ctx.quiz, :needs_review, 0, 10)
      submit(ctx.petrova, ctx.code, :processing, 0, 5)

      %{cells: cells} = Gradebook.build(ctx.cohort, ctx.course.id)

      assert %{state: :scored, score: 70, attempts: 2} = cells[{ctx.ivanov.id, ctx.quiz.id}]
      assert %{state: :review, score: nil} = cells[{ctx.petrova.id, ctx.quiz.id}]
      assert %{state: :in_progress, score: nil} = cells[{ctx.petrova.id, ctx.code.id}]
      refute Map.has_key?(cells, {ctx.ivanov.id, ctx.code.id})
    end
  end

  describe "build/3 - which submissions count" do
    test "drafts, exam children, daily challenges, test runs, team and outside work are ignored",
         ctx do
      outsider = insert(:account)
      team = insert(:cohort, type: :team)
      parent = submit(ctx.ivanov, ctx.exam, :graded, 80, 60)

      submit(ctx.ivanov, ctx.quiz, :draft, 0, 5)
      submit(ctx.ivanov, ctx.exam, :graded, 10, 50, parent_submission_id: parent.id)
      submit(ctx.ivanov, ctx.code, :graded, 100, 40, origin: :daily_challenge)
      submit(ctx.petrova, ctx.quiz, :graded, 100, 40, content: %{"is_test_run" => true})
      submit(ctx.petrova, ctx.code, :graded, 100, 40, cohort_id: team.id)
      submit(outsider, ctx.quiz, :graded, 100, 40)

      %{cells: cells} = Gradebook.build(ctx.cohort, ctx.course.id)

      assert Map.keys(cells) == [{ctx.ivanov.id, ctx.exam.id}]
      assert %{score: 80, attempts: 1} = cells[{ctx.ivanov.id, ctx.exam.id}]
    end

    test "a team cohort is a single row matched by the team's own submissions", ctx do
      team = insert(:cohort, type: :team, name: "Red Team")
      member = insert(:account)
      insert(:cohort_membership, account_id: member.id, cohort_id: team.id)
      submit(member, ctx.code, :accepted, 100, 10, cohort_id: team.id)
      submit(member, ctx.quiz, :graded, 100, 10)

      gradebook = Gradebook.build(team, ctx.course.id)

      assert [%{id: team_id, name: "Red Team"}] = gradebook.rows
      assert team_id == team.id
      assert Map.keys(gradebook.cells) == [{team.id, ctx.code.id}]
    end
  end

  describe "build/3 - filters" do
    test "block ids, block types and students narrow columns and rows", ctx do
      submit(ctx.ivanov, ctx.quiz, :graded, 50, 10)
      submit(ctx.petrova, ctx.exam, :graded, 50, 10)

      by_block = Gradebook.build(ctx.cohort, ctx.course.id, %{block_ids: [ctx.exam.id]})
      assert Enum.map(by_block.columns, & &1.block.id) == [ctx.exam.id]
      assert Map.keys(by_block.cells) == [{ctx.petrova.id, ctx.exam.id}]

      by_type = Gradebook.build(ctx.cohort, ctx.course.id, %{types: [:code, :quiz_question]})
      assert Enum.map(by_type.columns, & &1.block.id) == [ctx.quiz.id, ctx.code.id]

      by_student = Gradebook.build(ctx.cohort, ctx.course.id, %{account_ids: [ctx.ivanov.id]})
      assert Enum.map(by_student.rows, & &1.id) == [ctx.ivanov.id]
      assert length(by_student.all_rows) == 2
      assert Map.keys(by_student.cells) == [{ctx.ivanov.id, ctx.quiz.id}]
    end

    test "the date range limits which attempts are considered", ctx do
      submit(ctx.ivanov, ctx.quiz, :graded, 100, 3 * 24 * 60)
      submit(ctx.ivanov, ctx.quiz, :graded, 30, 10)

      today = Athena.TimeZones.today()

      recent =
        Gradebook.build(ctx.cohort, ctx.course.id, %{from: Date.add(today, -1), to: today})

      assert %{score: 30, attempts: 1} = recent.cells[{ctx.ivanov.id, ctx.quiz.id}]

      old = Gradebook.build(ctx.cohort, ctx.course.id, %{to: Date.add(today, -2)})
      assert %{score: 100, attempts: 1} = old.cells[{ctx.ivanov.id, ctx.quiz.id}]
    end
  end

  describe "status matching and summaries" do
    test "matches_status?/3" do
      scored = %{state: :scored, score: 40}

      assert Gradebook.matches_status?(scored, :all, 50)
      assert Gradebook.matches_status?(scored, :failed, 50)
      refute Gradebook.matches_status?(scored, :failed, 40)
      assert Gradebook.matches_status?(nil, :not_started, 50)
      refute Gradebook.matches_status?(scored, :not_started, 50)
      assert Gradebook.matches_status?(%{state: :review}, :review, 50)
      assert Gradebook.matches_status?(%{state: :in_progress}, :in_progress, 50)
    end

    test "row and column summaries", ctx do
      submit(ctx.ivanov, ctx.quiz, :graded, 40, 10)
      submit(ctx.ivanov, ctx.code, :accepted, 100, 10)
      submit(ctx.petrova, ctx.quiz, :needs_review, 0, 10)

      gradebook = Gradebook.build(ctx.cohort, ctx.course.id)
      block_ids = Enum.map(gradebook.columns, & &1.block.id)
      row_ids = Enum.map(gradebook.rows, & &1.id)

      assert %{average: 70.0, passed: 1, submitted: 2, total: 3} =
               Gradebook.row_summary(gradebook, ctx.ivanov.id, block_ids, 50)

      assert %{average: 40.0, passed: 0, submitted: 2, total: 2} =
               Gradebook.column_summary(gradebook, ctx.quiz.id, row_ids, 50)

      assert %{average: nil, submitted: 0} =
               Gradebook.column_summary(gradebook, ctx.exam.id, row_ids, 50)
    end
  end
end
