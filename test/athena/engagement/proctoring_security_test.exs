defmodule Athena.Engagement.ProctoringSecurityTest do
  use Athena.DataCase, async: false

  alias Athena.Engagement.{ProctoringCheckpoint, ProctoringMonitor}

  setup do
    sid = Ecto.UUID.generate()
    pid = start_supervised!({ProctoringMonitor, {sid, nil, Ecto.UUID.generate()}})
    %{sid: sid, pid: pid}
  end

  test "connected silence is retained when the heartbeat returns", %{sid: sid, pid: pid} do
    ProctoringMonitor.connection(sid, nil, nil, true)
    :sys.replace_state(pid, &%{&1 | last_event_at: ago(70)})
    ProctoringMonitor.heartbeat(sid, nil, nil)
    assert ProctoringMonitor.snapshot(sid).max_connected_silence_seconds >= 70
  end

  test "disconnected silence does not become connected silence on reconnect", %{
    sid: sid,
    pid: pid
  } do
    :sys.replace_state(pid, &%{&1 | last_event_at: ago(70)})
    ProctoringMonitor.connection(sid, nil, nil, true)
    reading = ProctoringMonitor.snapshot(sid)
    assert reading.max_silence_seconds >= 70
    assert reading.max_connected_silence_seconds == 0
  end

  test "session death is observed without relying on LiveView terminate", %{sid: sid, pid: pid} do
    session = start_supervised!({Agent, fn -> nil end})
    Agent.get(session, fn _ -> ProctoringMonitor.connection(sid, nil, nil, true) end)
    assert :sys.get_state(pid).connected
    Phoenix.PubSub.subscribe(Athena.PubSub, "proctoring:#{sid}")
    stop_supervised!(Agent)
    assert_receive {:proctoring_updated, ^sid}
    assert :sys.get_state(pid).connected == false
    :sys.replace_state(pid, &%{&1 | last_event_at: ago(70)})
    assert ProctoringMonitor.snapshot(sid).max_connected_silence_seconds == 0
  end

  test "two live sessions are detected immediately and deduplicated", %{sid: sid, pid: pid} do
    ProctoringMonitor.connection(sid, nil, nil, true)
    other = start_supervised!({Agent, fn -> nil end})
    Agent.get(other, fn _ -> ProctoringMonitor.connection(sid, nil, nil, true) end)
    reading = ProctoringMonitor.snapshot(sid)
    assert reading.counts.multi_tab_detected == 1
    assert Enum.any?(reading.incidents, &(&1["type"] == "concurrent_session"))
    send(pid, :check_idle)
    assert ProctoringMonitor.snapshot(sid).counts.multi_tab_detected == 1
  end

  test "heartbeat-only channel produces a review incident once", %{sid: sid, pid: pid} do
    ProctoringMonitor.connection(sid, nil, nil, true)
    :sys.replace_state(pid, &%{&1 | last_signal_at: ago(400)})
    ProctoringMonitor.heartbeat(sid, nil, nil)
    for _ <- 1..2, do: send(pid, :check_idle)
    reading = ProctoringMonitor.snapshot(sid)
    assert Enum.count(reading.incidents, &(&1["type"] == "inert_channel")) == 1
  end

  test "durations are bounded by server elapsed time and malformed paste cannot crash", %{
    sid: sid,
    pid: pid
  } do
    :sys.replace_state(pid, &%{&1 | started_at: ago(20)})

    ProctoringMonitor.report_events(sid, nil, nil, [
      %{event_type: :window_focus, payload: %{"duration_ms" => 1_000_000}},
      %{
        event_type: :paste_detected,
        payload: %{"pasted_chars" => "garbage", "total_chars" => -1}
      },
      %{event_type: :paste_detected, payload: %{"pasted_chars" => 500, "total_chars" => 100}}
    ])

    reading = ProctoringMonitor.snapshot(sid)
    assert reading.away_total_seconds == 20
    assert reading.counts.paste_ratio == 1.0
  end

  test "enormous JSON integers do not overflow floating-point aggregates", %{sid: sid, pid: pid} do
    huge = Integer.pow(10, 400)
    :sys.replace_state(pid, &%{&1 | started_at: ago(20)})

    ProctoringMonitor.report_events(sid, nil, nil, [
      %{event_type: :window_focus, payload: %{"duration_ms" => 10_000}},
      %{event_type: :paste_detected, payload: %{"pasted_chars" => huge, "total_chars" => huge}},
      %{
        event_type: :typing_summary,
        payload: %{"n" => huge, "median_dwell_ms" => huge, "flight_cv" => huge}
      }
    ])

    reading = ProctoringMonitor.snapshot(sid)
    assert reading.counts.paste_ratio == 1.0
    assert reading.typing.keys == 1_000_000_000
  end

  test "client timestamps cannot move a received absence into the distant past", %{
    sid: sid,
    pid: pid
  } do
    :sys.replace_state(pid, &%{&1 | started_at: ago(20)})

    ProctoringMonitor.report_events(sid, nil, nil, [
      %{event_type: :window_focus, occurred_at: ago(600), payload: %{"duration_ms" => 10_000}},
      %{event_type: :paste_detected, payload: %{"pasted_chars" => 500, "total_chars" => 500}}
    ])

    assert ProctoringMonitor.snapshot(sid).counts.large_paste == 1
  end

  test "checkpoint survives a stopped monitor and is consumed by finalize", %{sid: sid, pid: pid} do
    ProctoringMonitor.report_events(sid, nil, nil, [%{event_type: :copy_attempt}])
    send(pid, :check_idle)
    _ = :sys.get_state(pid)
    assert %{version: 1} = ProctoringCheckpoint.load(sid)
    stop_supervised!({ProctoringMonitor, sid})
    assert ProctoringMonitor.finalize(sid).counts.copy_attempt == 1
    assert ProctoringCheckpoint.load(sid) == nil
  end

  test "incompatible and corrupt checkpoints are ignored", %{sid: sid} do
    stop_supervised!({ProctoringMonitor, sid})

    for data <- [%{version: 99, state: %{}}, %{version: 1, state: %{counts: nil}}] do
      ProctoringCheckpoint.save(sid, data)
      start_supervised!({ProctoringMonitor, {sid, nil, nil}})
      assert ProctoringMonitor.snapshot(sid).counts.copy_attempt == 0
      stop_supervised!({ProctoringMonitor, sid})
    end

    Repo.update_all(ProctoringCheckpoint, set: [data: <<0, 1, 2>>])
    assert ProctoringCheckpoint.load(sid) == nil
  end

  test "purge removes stale checkpoints and preserves recent ones", %{sid: sid} do
    old_sid = Ecto.UUID.generate()
    ProctoringCheckpoint.save(sid, %{})
    ProctoringCheckpoint.save(old_sid, %{})

    from(c in ProctoringCheckpoint, where: c.submission_id == ^old_sid)
    |> Repo.update_all(set: [updated_at: ago(90_000)])

    assert ProctoringCheckpoint.purge_stale() == 1
    assert ProctoringCheckpoint.load(sid) == %{}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
end
