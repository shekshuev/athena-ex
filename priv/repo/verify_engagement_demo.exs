# Read-only sanity check: calls the exact same Athena.Engagement functions
# the dashboard calls, on the data seed_engagement_demo.exs created, using
# the SAME three windows the dashboard's period picker offers (7 days /
# 30 days / whole course) - not just "whole course" - since the dashboard
# defaults to the 7-day window and numbers genuinely differ by window.

alias Athena.{Repo, Engagement}
alias Athena.Identity.Account

path = Path.join(__DIR__, "seed_engagement_demo_ids.json")
data = path |> File.read!() |> Jason.decode!()
course_id = data["course_id"]

login_by_id = Repo.all(Account) |> Map.new(&{&1.id, &1.login})

now = DateTime.utc_now()

windows = [
  {"last 7 days (default dashboard view)", DateTime.add(now, -7 * 86_400, :second)},
  {"last 30 days", DateTime.add(now, -30 * 86_400, :second)},
  {"whole course", nil}
]

for {cohort_key, cohort_data} <- data["cohorts"] do
  cohort_id = cohort_data["cohort_id"]

  IO.puts("\n============================================================")
  IO.puts("Когорта: #{cohort_key} (#{cohort_id})")
  IO.puts("============================================================")

  for {window_label, since} <- windows do
    IO.puts("\n-- student_radar, window = #{window_label} --")

    Engagement.student_radar(cohort_id, course_id, since: since)
    |> Enum.sort_by(&login_by_id[&1.account_id])
    |> Enum.each(fn row ->
      IO.puts(
        "#{String.pad_trailing(login_by_id[row.account_id], 30)} " <>
          "status=#{row.status}  slacking=#{row.slacking_index}  struggling=#{row.struggling_index}  " <>
          "progress=#{Float.round(row.progress_percent, 1)}%"
      )
    end)
  end
end
