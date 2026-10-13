defmodule AthenaWeb.Bench.PlayerBenchTest do
  @moduledoc """
  Query-count benchmark for opening a lesson in the student player and for
  the live refreshes it reacts to, on a course sized like a real one
  (15 sections × 10 blocks, a gate in every section). Excluded by default
  (see `test_helper.exs`); run with:

      mix test test/bench --only bench

  Prints one line per step: wall time and number of SQL queries (the static
  and the connected render together for the page load). A measuring stick
  for before/after comparisons, not a pass/fail gate.
  """
  use AthenaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Content.CompletionRule

  @moduletag :bench
  @moduletag timeout: :infinity

  @sections 15
  @blocks_per_section 10

  setup %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})
    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)

    sections =
      for s <- 1..@sections do
        section = insert(:section, course: course, order: s, title: "Section #{s}")

        for b <- 1..@blocks_per_section do
          insert(:block,
            section: section,
            order: b * 10,
            type: if(b == @blocks_per_section, do: :quiz_question, else: :text),
            content: %{"body" => %{"type" => "doc", "text" => String.duplicate("x", 2_000)}},
            completion_rule:
              if(b == @blocks_per_section, do: %CompletionRule{type: :button}, else: nil)
          )
        end

        section
      end

    # The student is halfway through the course.
    for section <- Enum.take(sections, div(@sections, 2)) do
      gate =
        Athena.Repo.get_by!(Athena.Content.Block,
          section_id: section.id,
          order: @blocks_per_section * 10
        )

      Athena.Learning.mark_completed(user.id, gate.id)
    end

    %{conn: conn, course: course, section: Enum.at(sections, div(@sections, 2))}
  end

  test "player page load and refreshes", %{conn: conn, course: course, section: section} do
    path = ~p"/learn/courses/#{course.id}/play/#{section.id}"

    {:ok, lv, _html} = measure("player: open lesson", fn -> live(conn, path) end)

    measure("player: teammate progress", fn ->
      send(lv.pid, :team_progress_updated)
      render(lv)
    end)

    measure("player: content edited", fn ->
      send(lv.pid, :refresh_content)
      render(lv)
    end)
  end

  defp measure(label, fun) do
    counter = :counters.new(1, [])
    handler_id = "bench-#{label}"

    :telemetry.attach(
      handler_id,
      [:athena, :repo, :query],
      fn _event, _measurements, _meta, ref -> :counters.add(ref, 1, 1) end,
      counter
    )

    {micros, result} = :timer.tc(fun)
    :telemetry.detach(handler_id)

    IO.puts(
      String.pad_trailing(label, 32) <>
        String.pad_leading("#{div(micros, 1000)} ms", 10) <>
        String.pad_leading("#{:counters.get(counter, 1)} queries", 14)
    )

    result
  end
end
