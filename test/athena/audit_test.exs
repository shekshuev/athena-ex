defmodule Athena.AuditTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  require Logger

  alias Athena.Audit

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  describe "event/2" do
    test "writes one greppable line at :info" do
      log =
        capture_log(fn -> Audit.event("course.created", course_id: "abc", type: :standard) end)

      assert log =~ "[info]"
      assert log =~ "[event] course.created course_id=abc type=standard"
    end

    test "omits nil fields rather than logging key=" do
      log = capture_log(fn -> Audit.event("x.y", cohort_id: nil, account_id: "a1") end)

      assert log =~ "[event] x.y account_id=a1"
      refute log =~ "cohort_id"
    end

    test "quotes values that would break key=value parsing" do
      log = capture_log(fn -> Audit.event("course.created", title: "Базы данных") end)

      assert log =~ ~s(title="Базы данных")
    end

    test "logs a struct by its id instead of dumping the record" do
      log =
        capture_log(fn ->
          Audit.event("submission.submitted", submission: %Athena.Learning.Submission{id: "s1"})
        end)

      assert log =~ "submission=s1"
      refute log =~ "Submission{"
    end

    test "carries the process's correlation metadata" do
      log =
        capture_log(fn ->
          Logger.metadata(trace: "phx-ABC", user: "ivanov")
          Audit.event("block.completed", block_id: "b1")
        end)

      assert log =~ "trace=phx-ABC"
      assert log =~ "user=ivanov"
    after
      Logger.metadata(trace: nil, user: nil)
    end
  end

  describe "warning/2 and error/2" do
    test "use their own levels so refusals and failures stand out" do
      assert capture_log(fn -> Audit.warning("a.b", reason: :locked) end) =~
               "[warning] [event] a.b"

      assert capture_log(fn -> Audit.error("c.d", reason: :timeout) end) =~ "[error] [event] c.d"
    end
  end

  describe "on_ok/3" do
    test "logs and passes through on success" do
      log = capture_log(fn -> assert {:ok, 1} = Audit.on_ok({:ok, 1}, "n.ok", &[v: &1]) end)

      assert log =~ "[event] n.ok v=1"
    end

    test "stays silent and passes through on failure" do
      log =
        capture_log(fn ->
          assert {:error, :nope} =
                   Audit.on_ok({:error, :nope}, "n.ok", fn _ -> raise "unused" end)
        end)

      refute log =~ "[event]"
    end
  end

  describe "put_trace/1" do
    test "sets a correlation id for work outside a request" do
      log =
        capture_log(fn ->
          Audit.put_trace("sub-123")
          Audit.event("submission.graded", submission_id: "123")
        end)

      assert log =~ "trace=sub-123"
    after
      Logger.metadata(trace: nil)
    end
  end
end
