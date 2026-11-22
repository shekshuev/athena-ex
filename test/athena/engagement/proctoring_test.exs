defmodule Athena.Engagement.ProctoringTest do
  use ExUnit.Case, async: false

  alias Athena.Engagement.{ExamIntegrityStats, Proctoring}

  defp reading(counts, extra \\ %{}),
    do: Map.merge(%{counts: counts, elapsed_minutes: 10.0}, extra)

  defp evaluate(reading),
    do: Proctoring.evaluate(reading, Ecto.UUID.generate(), Ecto.UUID.generate())

  test "colours still follow the configured points thresholds" do
    assert Proctoring.risk_level(1) == :green
    assert Proctoring.risk_level(2) == :yellow
    assert Proctoring.risk_level(3) == :yellow
    assert Proctoring.risk_level(4) == :red
  end

  for event <- [
        :copy_attempt,
        :cut_attempt,
        :printscreen_attempt,
        :bulk_insert,
        :right_click_attempt,
        :answer_changed,
        :multi_tab_detected
      ] do
    @event event
    test "#{event} alone is recorded without scoring, even when repeated" do
      fields = evaluate(reading(%{@event => 100}))
      assert fields["points"] == 0
      assert fields["server_points"] == 0
      assert fields["risk_level"] == "green"
      assert fields["event_counts"][to_string(@event)] == 100
    end
  end

  test "a network outage and connected silence cannot create a cheating verdict" do
    fields =
      evaluate(
        reading(%{}, %{
          max_silence_seconds: 3600,
          max_offline_seconds: 7200,
          max_connected_silence_seconds: 3600
        })
      )

    assert fields["points"] == 0
    assert fields["heartbeat_silence_seconds"] == 7200
    assert fields["connected_silence_seconds"] == 3600
  end

  test "sampled focus conflicts are observations and never server corroboration" do
    fields = evaluate(reading(%{}, %{answer_contradictions: 20, unfocused_seconds: 900}))
    assert fields["answer_contradictions"] == 20
    assert fields["unreported_unfocused_seconds"] == 880
    assert fields["signals"] == []
    assert fields["server_points"] == 0
  end

  test "typing rhythms, clean answers and pointer movement never earn points" do
    fields =
      evaluate(
        reading(%{}, %{
          mouse_away_seconds: 600,
          typing: %{keys: 1000, chars_typed: 1000, chars_deleted: 0, dwell_sum: 0}
        })
      )

    assert fields["points"] == 0
    assert fields["typing"]["chars_typed"] == 1000
  end

  test "an absence earns at most yellow, regardless of duration or repetition" do
    assert evaluate(reading(%{}, %{away_total_seconds: 6}))["points"] == 0

    for {incidents, seconds} <- [{1, 10}, {3, 40}, {0, 90}, {100, 3000}] do
      fields = evaluate(reading(%{}, %{away_incidents: incidents, away_total_seconds: seconds}))
      assert fields["points"] == 2
      assert fields["risk_level"] == "yellow"
    end
  end

  test "large pastes are one bounded category, not red through repetition" do
    fields = evaluate(reading(%{large_paste: 20, paste_ratio: 0.95}))
    assert fields["points"] == 2
    assert fields["risk_level"] == "yellow"
    assert [%{"key" => "large_paste", "points" => 2, "value" => 20}] = fields["signals"]
    assert fields["outlier_metrics"] == %{}
  end

  test "unconfirmed client tab reports do not add to confirmed concurrent sessions" do
    fields = evaluate(reading(%{multi_tab_detected: 30}, %{server_multi_tab_detected: 1}))
    assert fields["points"] == 2
    assert fields["server_points"] == 2
    assert fields["client_points"] == 0

    assert [%{"key" => "multi_tab_detected", "origin" => "server", "value" => 1}] =
             fields["signals"]

    assert evaluate(reading(%{multi_tab_detected: 50}, %{server_multi_tab_detected: 20}))[
             "points"
           ] == 2
  end

  test "red requires a confirmed concurrent session and another signal" do
    client_only =
      evaluate(reading(%{large_paste: 1}, %{away_incidents: 3, away_total_seconds: 90}))

    assert client_only["points"] == 4
    assert client_only["risk_level"] == "yellow"
    confirmed = evaluate(reading(%{large_paste: 1}, %{server_multi_tab_detected: 1}))
    assert confirmed["points"] == 4
    assert confirmed["risk_level"] == "red"
    assert confirmed["server_points"] == 2
    assert confirmed["client_points"] == 2
  end

  test "the server corroboration policy can be explicitly configured" do
    old = Application.get_env(:athena, Athena.Engagement, [])

    Application.put_env(
      :athena,
      Athena.Engagement,
      Keyword.put(old, :exam_require_server_corroboration_for_red, false)
    )

    on_exit(fn -> Application.put_env(:athena, Athena.Engagement, old) end)
    assert evaluate(reading(%{large_paste: 1}, %{away_incidents: 3}))["risk_level"] == "red"
  end

  test "a narrow page or window alone does not earn points" do
    for extra <- [
          %{viewport_split_seconds: 7200},
          %{split_seconds: 7200},
          %{split_seconds: 299, split_peeks: 10}
        ] do
      assert evaluate(reading(%{split_screen: 20}, extra))["points"] == 0
    end

    fields = evaluate(reading(%{}, %{split_seconds: 600, split_peeks: 3}))
    assert fields["points"] == 1
    assert fields["risk_level"] == "green"
    assert [%{"key" => "split_screen", "origin" => "client"}] = fields["signals"]
  end

  test "paste ratios still use group comparisons and never count twice with a large paste" do
    cohort = Ecto.UUID.generate()
    block = Ecto.UUID.generate()

    for n <- 1..10,
        do: ExamIntegrityStats.report_rate(cohort, block, "peer-#{n}", :paste_ratio, 0.1)

    assert {:ok, pid} = ExamIntegrityStats.get_or_start(cohort, block)
    _ = :sys.get_state(pid)
    fields = Proctoring.evaluate(reading(%{paste_ratio: 0.9}), cohort, block)
    assert fields["points"] == 2
    assert fields["outlier_metrics"]["paste_ratio"] == 0.9
    assert fields["group_baselines"]["paste_ratio"]["peers"] == 10
    assert [%{"key" => "paste_ratio", "basis" => "group"}] = fields["signals"]
  end

  test "group thresholds retain floors and protect small groups" do
    t = Proctoring.thresholds()
    assert Proctoring.group_threshold(:paste_ratio, %{n: 2, median: 0, spread: 0}, t) == 0.4
    assert Proctoring.group_threshold(:paste_ratio, %{n: 20, median: 0, spread: 0}, t) == 0.2

    assert_in_delta Proctoring.group_threshold(
                      :paste_ratio,
                      %{n: 20, median: 0.3, spread: 0.1},
                      t
                    ),
                    0.9,
                    0.000001

    assert Proctoring.group_threshold(:paste_ratio, %{n: 20, median: 0.2, spread: 0.4}, t) > 1.0
  end

  test "rates are measured without penalising frequent revisions or right clicks" do
    fields =
      evaluate(reading(%{answer_changed: 500, right_click_attempt: 200}, %{away_count: 100}))

    assert fields["rates"]["answer_changed_per_minute"] == 50.0
    assert fields["rates"]["right_click_per_minute"] == 20.0
    assert fields["points"] == 0
  end

  test "evaluation and detail preserve measured observations and scoring version" do
    incident = %{"type" => "clock_skew", "at" => "2026-11-22T10:00:00Z"}

    fields =
      evaluate(reading(%{copy_attempt: 2}, %{incidents: [incident], extended_display: true}))

    detail = Proctoring.detail(fields)
    assert fields["scoring_version"] == 2
    assert detail.scoring_version == 2
    assert detail.event_counts["copy_attempt"] == 2
    assert detail.extended_display
    assert detail.incidents == [incident]
    assert detail.risk_level == :green
    assert fields["hard_evidence_count"] == 0
  end

  test "old results and submissions without monitoring remain readable" do
    assert Proctoring.summary(nil) == nil
    assert Proctoring.summary(%{}) == nil
    assert Proctoring.detail(%{}) == nil
    assert Proctoring.detail(%{"risk_level" => "red"}).scoring_version == nil
    assert Proctoring.summary(%{"risk_level" => "yellow"}).risk_level == :yellow
  end
end
