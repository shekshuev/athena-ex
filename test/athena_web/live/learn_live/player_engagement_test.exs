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

  test "carries from_block_id through on a viewport_enter, unchanged", %{
    lv: lv,
    block: block
  } do
    other_block_id = Ecto.UUID.generate()

    render_hook(lv, "engagement_batch", %{
      "events" => [
        %{
          "block_id" => block.id,
          "event_type" => "viewport_enter",
          "payload" => %{"from_block_id" => other_block_id},
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      ]
    })

    stored = Repo.all(Event)

    assert [%{event_type: :viewport_enter, payload: %{"from_block_id" => ^other_block_id}}] =
             stored
  end

  test "records idle_start/idle_end events reported by the idle tracker", %{
    lv: lv,
    user: user,
    block: block
  } do
    render_hook(lv, "engagement_batch", %{
      "events" => [
        %{
          "block_id" => block.id,
          "event_type" => "idle_start",
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
        },
        %{
          "block_id" => block.id,
          "event_type" => "idle_end",
          "payload" => %{"duration_ms" => 125_000},
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      ]
    })

    stored = Repo.all(Event)
    assert length(stored) == 2
    assert Enum.all?(stored, &(&1.account_id == user.id))
    assert Enum.any?(stored, &(&1.event_type == :idle_start))

    assert Enum.any?(
             stored,
             &(&1.event_type == :idle_end and &1.payload["duration_ms"] == 125_000)
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
            "event_type" => "scroll_milestone",
            "payload" => %{"percent" => 100},
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
            "event_type" => "scroll_milestone",
            "payload" => %{"percent" => 100},
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
              "event_type" => "scroll_milestone",
              "payload" => %{"percent" => 100},
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

  describe "additional nudge triggers (scroll depth, paste ratio, video skip)" do
    alias Athena.Content.EngagementRule

    setup %{conn: conn} do
      user = insert(:account)
      conn = init_test_session(conn, %{"account_id" => user.id})

      cohort = insert(:cohort, nudges_enabled: true)
      insert(:cohort_membership, account_id: user.id, cohort_id: cohort.id)

      course = insert(:course)
      insert(:enrollment, course_id: course.id, cohort_id: cohort.id)

      section = insert(:section, course: course, title: "Nudge Section")

      # A generous expected_seconds/floor so none of these scenarios could
      # accidentally also trip the (separately tested) fast_dwell path -
      # each test below isolates exactly one new trigger.
      text_block =
        insert(:block,
          section: section,
          type: :text,
          order: 10,
          engagement_rule: %EngagementRule{expected_seconds: 1, fast_ratio_threshold: 0.01}
        )

      code_block =
        insert(:block,
          section: section,
          type: :code,
          order: 20,
          engagement_rule: %EngagementRule{expected_seconds: 1, fast_ratio_threshold: 0.01}
        )

      video_block =
        insert(:block,
          section: section,
          type: :video,
          order: 30,
          engagement_rule: %EngagementRule{expected_seconds: 1, fast_ratio_threshold: 0.01}
        )

      %{
        conn: conn,
        course: course,
        section: section,
        text_block: text_block,
        code_block: code_block,
        video_block: video_block
      }
    end

    test "nudges on shallow scroll even when dwell time is generous", %{
      conn: conn,
      course: course,
      section: section,
      text_block: block
    } do
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
            "event_type" => "scroll_milestone",
            "payload" => %{"percent" => 25},
            "occurred_at" => DateTime.to_iso8601(now)
          },
          %{
            "block_id" => block.id,
            "event_type" => "viewport_exit",
            "occurred_at" => DateTime.to_iso8601(DateTime.add(now, 600, :second))
          }
        ]
      })

      assert render(lv) =~ "scrolled past without reading much"

      assert Enum.any?(
               Repo.all(Event),
               &(&1.event_type == :nudge_shown and &1.payload["reason"] == "shallow_scroll")
             )
    end

    test "does not nudge on scroll depth once the student scrolled past the threshold", %{
      conn: conn,
      course: course,
      section: section,
      text_block: block
    } do
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
            "event_type" => "scroll_milestone",
            "payload" => %{"percent" => 100},
            "occurred_at" => DateTime.to_iso8601(now)
          },
          %{
            "block_id" => block.id,
            "event_type" => "viewport_exit",
            "occurred_at" => DateTime.to_iso8601(DateTime.add(now, 600, :second))
          }
        ]
      })

      refute render(lv) =~ "scrolled past without reading much"
      refute Enum.any?(Repo.all(Event), &(&1.event_type == :nudge_shown))
    end

    test "nudges immediately on a heavy paste, without waiting for viewport_exit", %{
      conn: conn,
      course: course,
      section: section,
      code_block: block
    } do
      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => block.id,
            "event_type" => "paste_detected",
            "payload" => %{"pasted_chars" => 95, "total_chars" => 100},
            "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        ]
      })

      assert render(lv) =~ "pasted a ready-made answer"

      assert Enum.any?(
               Repo.all(Event),
               &(&1.event_type == :nudge_shown and &1.payload["reason"] == "heavy_paste")
             )
    end

    test "does not nudge on a light paste below the ratio threshold", %{
      conn: conn,
      course: course,
      section: section,
      code_block: block
    } do
      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => block.id,
            "event_type" => "paste_detected",
            "payload" => %{"pasted_chars" => 5, "total_chars" => 100},
            "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
          }
        ]
      })

      refute render(lv) =~ "pasted a ready-made answer"
      refute Enum.any?(Repo.all(Event), &(&1.event_type == :nudge_shown))
    end

    test "nudges when most of a video was skipped via forward seeks", %{
      conn: conn,
      course: course,
      section: section,
      video_block: block
    } do
      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => block.id,
            "event_type" => "video_seek",
            "payload" => %{"from_sec" => 0, "to_sec" => 80},
            "occurred_at" => DateTime.to_iso8601(now)
          },
          %{
            "block_id" => block.id,
            "event_type" => "video_ended",
            "payload" => %{"duration" => 100},
            "occurred_at" => DateTime.to_iso8601(DateTime.add(now, 1, :second))
          }
        ]
      })

      assert render(lv) =~ "skipped through most of that video"

      assert Enum.any?(
               Repo.all(Event),
               &(&1.event_type == :nudge_shown and &1.payload["reason"] == "video_skipped")
             )
    end

    test "does not nudge when only a small part of the video was skipped", %{
      conn: conn,
      course: course,
      section: section,
      video_block: block
    } do
      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => block.id,
            "event_type" => "video_seek",
            "payload" => %{"from_sec" => 0, "to_sec" => 5},
            "occurred_at" => DateTime.to_iso8601(now)
          },
          %{
            "block_id" => block.id,
            "event_type" => "video_ended",
            "payload" => %{"duration" => 100},
            "occurred_at" => DateTime.to_iso8601(DateTime.add(now, 1, :second))
          }
        ]
      })

      refute render(lv) =~ "skipped through most of that video"
      refute Enum.any?(Repo.all(Event), &(&1.event_type == :nudge_shown))
    end

    test "shallow_scroll and heavy_paste can both fire independently on different blocks", %{
      conn: conn,
      course: course,
      section: section,
      text_block: text_block,
      code_block: code_block
    } do
      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      render_hook(lv, "engagement_batch", %{
        "events" => [
          %{
            "block_id" => text_block.id,
            "event_type" => "viewport_enter",
            "occurred_at" => DateTime.to_iso8601(now)
          },
          %{
            "block_id" => text_block.id,
            "event_type" => "viewport_exit",
            "occurred_at" => DateTime.to_iso8601(DateTime.add(now, 600, :second))
          },
          %{
            "block_id" => code_block.id,
            "event_type" => "paste_detected",
            "payload" => %{"pasted_chars" => 95, "total_chars" => 100},
            "occurred_at" => DateTime.to_iso8601(now)
          }
        ]
      })

      reasons =
        Repo.all(Event)
        |> Enum.filter(&(&1.event_type == :nudge_shown))
        |> Enum.map(& &1.payload["reason"])
        |> Enum.sort()

      assert reasons == ["heavy_paste", "shallow_scroll"]
    end
  end

  describe "code_run_attempt / code_run_result" do
    setup %{conn: conn} do
      user = insert(:account)
      conn = init_test_session(conn, %{"account_id" => user.id})

      course = insert(:course)
      insert(:enrollment, account_id: user.id, course_id: course.id)

      section = insert(:section, course: course, title: "Code Section")
      block = insert(:block, section: section, type: :code, content: %{"language" => "python3"})

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

      %{lv: lv, user: user, block: block}
    end

    test "records a code_run_attempt as soon as Run is clicked", %{lv: lv, block: block} do
      render_click(lv, "run_code", %{"block_id" => block.id})

      assert Enum.any?(
               Repo.all(Event),
               &(&1.event_type == :code_run_attempt and &1.block_id == block.id)
             )
    end

    test "records a code_run_result once the async grading result arrives", %{
      lv: lv,
      user: user,
      block: block
    } do
      submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :wrong_answer,
          score: 0
        )

      send(lv.pid, {:submission_updated, submission})
      render(lv)

      assert Enum.any?(
               Repo.all(Event),
               &(&1.event_type == :code_run_result and &1.payload["outcome"] == "wrong_answer")
             )
    end

    test "does not record a code_run_result for an in-progress (pending/processing) update", %{
      lv: lv,
      user: user,
      block: block
    } do
      submission =
        insert(:submission,
          account_id: user.id,
          block_id: block.id,
          status: :processing,
          score: 0
        )

      send(lv.pid, {:submission_updated, submission})
      render(lv)

      refute Enum.any?(Repo.all(Event), &(&1.event_type == :code_run_result))
    end
  end

  describe "answer_selected / answer_changed / first_interaction (via save_draft)" do
    setup %{conn: conn} do
      user = insert(:account)
      conn = init_test_session(conn, %{"account_id" => user.id})

      course = insert(:course)
      insert(:enrollment, account_id: user.id, course_id: course.id)

      section = insert(:section, course: course, title: "Quiz Section")

      block =
        insert(:block,
          section: section,
          type: :quiz_question,
          content: %{"question_type" => "exact_match", "answer_type" => "plain_text"}
        )

      {:ok, lv, _html} = live(conn, ~p"/learn/courses/#{course.id}/play/#{section.id}")

      %{lv: lv, block: block}
    end

    test "the first save_draft records first_interaction and answer_selected", %{
      lv: lv,
      block: block
    } do
      render_change(lv, "save_draft", %{"block_id" => block.id, "answer" => "first guess"})

      stored = Repo.all(Event) |> Enum.filter(&(&1.block_id == block.id))
      types = stored |> Enum.map(& &1.event_type) |> Enum.sort()

      assert types == [:answer_selected, :first_interaction]
    end

    test "a second save_draft records answer_changed instead, not another answer_selected", %{
      lv: lv,
      block: block
    } do
      render_change(lv, "save_draft", %{"block_id" => block.id, "answer" => "first guess"})
      render_change(lv, "save_draft", %{"block_id" => block.id, "answer" => "second guess"})

      stored = Repo.all(Event) |> Enum.filter(&(&1.block_id == block.id))
      types = stored |> Enum.map(& &1.event_type) |> Enum.sort()

      assert types == [:answer_changed, :answer_selected, :first_interaction]
      assert Enum.count(stored, &(&1.event_type == :answer_changed)) == 1
      assert Enum.count(stored, &(&1.event_type == :first_interaction)) == 1
    end
  end
end
