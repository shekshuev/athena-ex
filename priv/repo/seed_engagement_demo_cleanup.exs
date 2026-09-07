# Removes exactly the data created by seed_engagement_demo.exs, read back
# from priv/repo/seed_engagement_demo_ids.json (never matches by name/title,
# only by the ids that script recorded).
#
#     mix run priv/repo/seed_engagement_demo_cleanup.exs

alias Athena.Repo
alias Athena.Content.{Course, Section, Block}
alias Athena.Learning.{Cohort, CohortMembership, Enrollment, BlockProgress}
alias Athena.Engagement.Event
alias Athena.Identity.Account

import Ecto.Query

path = Path.join(__DIR__, "seed_engagement_demo_ids.json")

unless File.exists?(path) do
  raise "#{path} not found - nothing to clean up (or it was already removed)."
end

data = path |> File.read!() |> Jason.decode!()

course_id = data["course_id"]
teacher_id = data["teacher_account_id"]

student_ids =
  data["cohorts"]
  |> Map.values()
  |> Enum.flat_map(& &1["student_account_ids"])

cohort_ids = data["cohorts"] |> Map.values() |> Enum.map(& &1["cohort_id"])
all_account_ids = [teacher_id | student_ids]

Repo.transaction(fn ->
  block_ids =
    from(b in Block,
      join: s in Section,
      on: b.section_id == s.id,
      where: s.course_id == ^course_id,
      select: b.id
    )
    |> Repo.all()

  {events_count, _} = Repo.delete_all(from(e in Event, where: e.block_id in ^block_ids))
  IO.puts("Deleted #{events_count} engagement events")

  {progress_count, _} =
    Repo.delete_all(from(p in BlockProgress, where: p.block_id in ^block_ids))

  IO.puts("Deleted #{progress_count} block_progress rows")

  {enrollment_count, _} =
    Repo.delete_all(from(e in Enrollment, where: e.cohort_id in ^cohort_ids))

  IO.puts("Deleted #{enrollment_count} enrollments")

  {membership_count, _} =
    Repo.delete_all(from(m in CohortMembership, where: m.cohort_id in ^cohort_ids))

  IO.puts("Deleted #{membership_count} cohort memberships")

  {cohort_count, _} = Repo.delete_all(from(c in Cohort, where: c.id in ^cohort_ids))
  IO.puts("Deleted #{cohort_count} cohorts")

  {block_count, _} = Repo.delete_all(from(b in Block, where: b.id in ^block_ids))
  IO.puts("Deleted #{block_count} blocks")

  {section_count, _} = Repo.delete_all(from(s in Section, where: s.course_id == ^course_id))
  IO.puts("Deleted #{section_count} sections")

  {course_count, _} = Repo.delete_all(from(c in Course, where: c.id == ^course_id))
  IO.puts("Deleted #{course_count} course")

  {account_count, _} = Repo.delete_all(from(a in Account, where: a.id in ^all_account_ids))
  IO.puts("Deleted #{account_count} accounts (teacher + students)")
end)

File.rm!(path)
IO.puts("\nDone. Removed #{path}.")
