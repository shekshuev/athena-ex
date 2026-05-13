import Ecto.Query
alias Athena.Repo
alias Athena.Content.{Course, Section, Block}
alias Athena.Identity.Account
alias Athena.Learning.{Cohort, Enrollment, CohortMembership}

IO.puts("INITIALIZING CLEANUP PROCESS...")

{deleted_bots, _} = Repo.delete_all(from a in Account, where: like(a.login, "bot_%"))

course_query = from c in Course, where: like(c.title, "STRESS-TEST-COURSE-%")
courses = Repo.all(from c in course_query, select: c.id)

{deleted_blocks, deleted_sections} = if length(courses) > 0 do
  sections = Repo.all(from s in Section, where: s.course_id in ^courses, select: s.id)
  
  res = if length(sections) > 0 do
    {b, _} = Repo.delete_all(from b in Block, where: b.section_id in ^sections)
    {s, _} = Repo.delete_all(from s in Section, where: s.id in ^sections)
    {b, s}
  else
    {0, 0}
  end

  Repo.delete_all(from e in Enrollment, where: e.course_id in ^courses)
  Repo.delete_all(course_query)
  res
else
  {0, 0}
end

cohort_query = from c in Cohort, where: like(c.name, "STRESS-TEST-COHORT-%")
cohorts = Repo.all(from c in cohort_query, select: c.id)

deleted_cohorts = if length(cohorts) > 0 do
  Repo.delete_all(from cm in CohortMembership, where: cm.cohort_id in ^cohorts)
  {count, _} = Repo.delete_all(cohort_query)
  count
else
  0
end

config_status = case File.rm("./targets.json") do
  :ok -> "REMOVED"
  _   -> "NOT FOUND"
end

IO.puts("""
+-----------------------------------------------------------+
| CLEANUP COMPLETED SUCCESSFULLY                            |
+-----------------------------------------------------------+
| Accounts removed:  #{String.pad_trailing("#{deleted_bots}", 38)} |
| Courses removed:   #{String.pad_trailing("#{length(courses)}", 38)} |
| Sections removed:  #{String.pad_trailing("#{deleted_sections}", 38)} |
| Blocks removed:    #{String.pad_trailing("#{deleted_blocks}", 38)} |
| Cohorts removed:   #{String.pad_trailing("#{deleted_cohorts}", 38)} |
| Config file:       #{String.pad_trailing(config_status, 38)} |
+-----------------------------------------------------------+
""")