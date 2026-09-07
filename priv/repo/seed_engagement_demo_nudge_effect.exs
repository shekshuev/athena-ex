# One-off addendum to seed_engagement_demo.exs: gives the *experimental*
# cohort's slacker students a second, well-behaved pass on the blocks they
# were nudged on, timestamped after the nudge - so nudge_correction_rate and
# cohort_flag_profile actually differ between the experimental and control
# cohort (the whole point of seeding two cohorts). The *control* cohort's
# slackers are deliberately left as-is (nudges_enabled: false there - no
# behavior change expected, and none seeded).
#
#     mix run priv/repo/seed_engagement_demo_nudge_effect.exs

import Ecto.Query

alias Athena.{Repo, Engagement}
alias Athena.Identity.Account
alias Athena.Content.{Block, Section}

path = Path.join(__DIR__, "seed_engagement_demo_ids.json")
data = path |> File.read!() |> Jason.decode!()
course_id = data["course_id"]
experimental_cohort_id = data["cohorts"]["experimental"]["cohort_id"]

now = DateTime.utc_now() |> DateTime.truncate(:second)

defmodule NudgeEffect do
  alias Athena.Engagement

  def record(account_id, cohort_id, session_id, block, event_type, occurred_at, payload \\ %{}) do
    {:ok, _} =
      Engagement.record_events(account_id, cohort_id, session_id, [
        %{
          block_id: block.id,
          section_id: block.section_id,
          event_type: event_type,
          payload: payload,
          occurred_at: occurred_at
        }
      ])
  end

  def dwell(account_id, cohort_id, block, at, duration_seconds) do
    session = Ecto.UUID.generate()
    record(account_id, cohort_id, session, block, :viewport_enter, at)

    record(
      account_id,
      cohort_id,
      session,
      block,
      :viewport_exit,
      DateTime.add(at, duration_seconds, :second)
    )
  end
end

[text1, text2] =
  from(b in Block,
    join: s in Section,
    on: b.section_id == s.id,
    where: s.course_id == ^course_id and b.type == :text,
    order_by: [s.order, b.order]
  )
  |> Repo.all()

quiz1 =
  Repo.one!(
    from(b in Block,
      join: s in Section,
      on: b.section_id == s.id,
      where: s.course_id == ^course_id and b.type == :quiz_question and s.order == 10
    )
  )

code =
  Repo.one!(
    from(b in Block,
      join: s in Section,
      on: b.section_id == s.id,
      where: s.course_id == ^course_id and b.type == :code
    )
  )

video =
  Repo.one!(
    from(b in Block,
      join: s in Section,
      on: b.section_id == s.id,
      where: s.course_id == ^course_id and b.type == :video
    )
  )

quiz2 =
  Repo.one!(
    from(b in Block,
      join: s in Section,
      on: b.section_id == s.id,
      where: s.course_id == ^course_id and b.type == :quiz_question and s.order == 30
    )
  )

slacker_ids =
  Repo.all(
    from(a in Account,
      where: like(a.login, "demo_experimental_slacker%"),
      select: {a.login, a.id}
    )
  )

for {_login, account_id} <- slacker_ids do
  # Normal-paced dwell now (well after the original nudges) - no more
  # fast_dwell/shallow_scroll/heavy_paste/video_skipped on any of these.
  NudgeEffect.dwell(account_id, experimental_cohort_id, text1, now, 300)

  NudgeEffect.record(
    account_id,
    experimental_cohort_id,
    Ecto.UUID.generate(),
    text1,
    :scroll_milestone,
    now,
    %{"percent" => 100}
  )

  NudgeEffect.dwell(account_id, experimental_cohort_id, quiz1, DateTime.add(now, 400, :second), 180)

  NudgeEffect.dwell(account_id, experimental_cohort_id, text2, DateTime.add(now, 700, :second), 400)

  NudgeEffect.record(
    account_id,
    experimental_cohort_id,
    Ecto.UUID.generate(),
    text2,
    :scroll_milestone,
    DateTime.add(now, 700, :second),
    %{"percent" => 100}
  )

  code_session = Ecto.UUID.generate()
  code_at = DateTime.add(now, 1200, :second)
  NudgeEffect.record(account_id, experimental_cohort_id, code_session, code, :code_run_attempt, code_at)

  NudgeEffect.record(
    account_id,
    experimental_cohort_id,
    code_session,
    code,
    :code_run_result,
    DateTime.add(code_at, 60, :second),
    %{"outcome" => "accepted"}
  )

  video_session = Ecto.UUID.generate()
  video_at = DateTime.add(now, 1400, :second)
  NudgeEffect.record(account_id, experimental_cohort_id, video_session, video, :video_play, video_at)

  NudgeEffect.record(
    account_id,
    experimental_cohort_id,
    video_session,
    video,
    :video_ended,
    DateTime.add(video_at, 600, :second),
    %{"duration" => 600}
  )

  NudgeEffect.dwell(account_id, experimental_cohort_id, quiz2, DateTime.add(now, 2100, :second), 200)
end

IO.puts("Added corrective follow-up events for #{length(slacker_ids)} experimental-cohort slackers.")
