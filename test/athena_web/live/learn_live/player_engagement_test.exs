defmodule AthenaWeb.LearnLive.PlayerEngagementTest do
  # Not async: nudge evaluation starts an `Athena.Engagement.BlockStats`
  # process (a separate OS process from the test) that bootstraps itself
  # with its own DB query - that only has sandbox access when the sandbox
  # connection is shared (`shared: true`, which `Athena.DataCase`/
  # `AthenaWeb.ConnCase` only use for `async: false`).
  use AthenaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  import Athena.Factory

  alias Athena.Engagement.Event
  alias Athena.Repo

  setup %{conn: conn} do
    user = insert(:account)
    conn = init_test_session(conn, %{"account_id" => user.id})

    course = insert(:course)
    insert(:enrollment, account_id: user.id, course_id: course.id)

    section = insert(:section, course: course, title: "Engagement Section")
    block = insert(:block, section: section, type: :text, order: 10)

    {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

    %{lv: lv, user: user, block: block, section: section}
  end

  test "records a valid batch of events reported by the client hook", %{
    lv: lv,
    user: user,
    block: block
  } do
    render_hook(lv, "engagement_batch", %{
      "events" => [
        %{
          "block_id" => block.id,
          "event_type" => "viewport_enter",
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
        },
        %{
          "block_id" => block.id,
          "event_type" => "scroll_milestone",
          "payload" => %{"percent" => 50},
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      ]
    })

    stored = Repo.all(Event)
    assert length(stored) == 2
    assert Enum.all?(stored, &(&1.account_id == user.id))
    assert Enum.all?(stored, &(&1.block_id == block.id))
    assert Enum.any?(stored, &(&1.event_type == :viewport_enter))

    assert Enum.any?(
             stored,
             &(&1.event_type == :scroll_milestone and &1.payload["percent"] == 50)
           )
  end

  test "silently drops events with an unknown event_type instead of crashing", %{
    lv: lv,
    block: block
  } do
    render_hook(lv, "engagement_batch", %{
      "events" => [
        %{
          "block_id" => block.id,
          "event_type" => "totally_made_up",
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      ]
    })

    assert Process.alive?(lv.pid)
    assert Repo.all(Event) == []
  end

  test "silently drops events missing required fields", %{lv: lv} do
    render_hook(lv, "engagement_batch", %{"events" => [%{"event_type" => "viewport_enter"}]})

    assert Process.alive?(lv.pid)
    assert Repo.all(Event) == []
  end

  describe "nudges" do
    alias Athena.Content.EngagementRule

    setup %{conn: conn} do
      user = insert(:account)
      conn = init_test_session(conn, %{"account_id" => user.id})

      cohort = insert(:cohort, nudges_enabled: true)
      insert(:cohort_membership, account_id: user.id, cohort_id: cohort.id)

      course = insert(:course)
      insert(:enrollment, course_id: course.id, cohort_id: cohort.id)

      section = insert(:section, course: course, title: "Nudge Section")

      block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 100, fast_ratio_threshold: 0.5}
        )

      %{conn: conn, user: user, cohort: cohort, course: course, section: section, block: block}
    end

    test "flashes a warning and records nudge_shown when a block is exited far faster than its floor",
         %{conn: conn, course: course, section: section, block: block} do
      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      # floor is 100 * 0.5 = 50s; 5s dwell should trigger a nudge.
      exited_at = DateTime.add(now, 5, :second)

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => block.id,
            "event_type" => "viewport_enter",
            "occurred_at" => DateTime.to_iso8601(now)
          },
          %{
            "block_id" => block.id,
            "event_type" => "viewport_exit",
            "occurred_at" => DateTime.to_iso8601(exited_at)
          }
        ]
      })

      assert render(lv) =~ "went through that pretty fast"

      assert Enum.any?(
               Repo.all(Event),
               &(&1.event_type == :nudge_shown and &1.block_id == block.id)
             )
    end

    test "does not nudge when the dwell is comfortably above the floor",
         %{conn: conn, course: course, section: section, block: block} do
      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      exited_at = DateTime.add(now, 120, :second)

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => block.id,
            "event_type" => "viewport_enter",
            "occurred_at" => DateTime.to_iso8601(now)
          },
          %{
            "block_id" => block.id,
            "event_type" => "viewport_exit",
            "occurred_at" => DateTime.to_iso8601(exited_at)
          }
        ]
      })

      refute render(lv) =~ "went through that pretty fast"
      refute Enum.any?(Repo.all(Event), &(&1.event_type == :nudge_shown))
    end

    test "does not nudge twice for the same block within one session",
         %{conn: conn, course: course, section: section, block: block} do
      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

      fast_pair = fn enter_offset, exit_offset ->
        base = DateTime.utc_now() |> DateTime.truncate(:second)

        %{
          "events" => [
            %{
              "block_id" => block.id,
              "event_type" => "viewport_enter",
              "occurred_at" => DateTime.to_iso8601(DateTime.add(base, enter_offset, :second))
            },
            %{
              "block_id" => block.id,
              "event_type" => "viewport_exit",
              "occurred_at" => DateTime.to_iso8601(DateTime.add(base, exit_offset, :second))
            }
          ]
        }
      end

      render_hook(lv, "engagement_batch", fast_pair.(0, 3))
      render_hook(lv, "engagement_batch", fast_pair.(10, 13))

      nudge_events = Enum.filter(Repo.all(Event), &(&1.event_type == :nudge_shown))
      assert length(nudge_events) == 1
    end

    test "never nudges when the cohort has nudges disabled", %{
      course: course,
      section: section,
      block: block
    } do
      other_user = insert(:account)
      conn = build_conn() |> init_test_session(%{"account_id" => other_user.id})

      disabled_cohort = insert(:cohort, nudges_enabled: false)
      insert(:cohort_membership, account_id: other_user.id, cohort_id: disabled_cohort.id)
      insert(:enrollment, course_id: course.id, cohort_id: disabled_cohort.id)

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => block.id,
            "event_type" => "viewport_enter",
            "occurred_at" => DateTime.to_iso8601(now)
          },
          %{
            "block_id" => block.id,
            "event_type" => "viewport_exit",
            "occurred_at" => DateTime.to_iso8601(DateTime.add(now, 2, :second))
          }
        ]
      })

      refute render(lv) =~ "went through that pretty fast"
      refute Enum.any?(Repo.all(Event), &(&1.event_type == :nudge_shown))
    end
  end
end
