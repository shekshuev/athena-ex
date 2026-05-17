import Ecto.Query, warn: false
alias Athena.Repo
alias Athena.Content.{Course, Section, Block}
alias Athena.Identity.{Account, Role}
alias Athena.Learning.{Cohort, Enrollment, CohortMembership}

Logger.configure(level: :info)

students_count = 1000
sections_count = 1000
blocks_per_section = 1000

IO.puts("INITIALIZING SEED PROCESS...")
t0 = System.monotonic_time()

role = Repo.all(Role) |> List.first()
admin = Repo.all(Account) |> List.first()

suffix = :erlang.unique_integer([:positive])
course_id = Ecto.UUID.generate()
cohort_id = Ecto.UUID.generate()
now = DateTime.utc_now() |> DateTime.truncate(:second)

IO.write("Creating course and cohort... ")

{1, _} =
  Repo.insert_all(Course, [
    %{
      id: course_id,
      title: "STRESS-TEST-COURSE-#{suffix}",
      status: :published,
      type: :standard,
      is_public: false,
      owner_id: admin.id,
      inserted_at: now,
      updated_at: now
    }
  ])

{1, _} =
  Repo.insert_all(Cohort, [
    %{
      id: cohort_id,
      name: "STRESS-TEST-COHORT-#{suffix}",
      type: :academic,
      owner_id: admin.id,
      inserted_at: now,
      updated_at: now
    }
  ])

{1, _} =
  Repo.insert_all(Enrollment, [
    %{
      id: Ecto.UUID.generate(),
      course_id: course_id,
      cohort_id: cohort_id,
      status: :active,
      inserted_at: now,
      updated_at: now
    }
  ])

IO.puts("Done.")

IO.write("Generating #{sections_count} sections... ")

sections =
  Enum.map(1..sections_count, fn i ->
    sec_id = Ecto.UUID.generate()

    %{
      id: sec_id,
      title: "Section #{i}",
      order: i,
      course_id: course_id,
      path: %EctoLtree.LabelTree{labels: [Athena.Content.Section.uuid_to_ltree(sec_id)]},
      visibility: :enrolled,
      inserted_at: now,
      updated_at: now
    }
  end)

{^sections_count, _} = Repo.insert_all(Section, sections)
IO.puts("Done.")

IO.write("Generating #{sections_count * blocks_per_section} blocks... ")

blocks =
  Enum.flat_map(sections, fn section ->
    Enum.map(1..blocks_per_section, fn j ->
      %{
        id: Ecto.UUID.generate(),
        section_id: section.id,
        type: :code,
        order: j * 1024,
        visibility: :enrolled,
        content: %{
          "language" => "python3",
          "test_cases" => [
            %{"id" => "tc1", "input" => "1", "expected_output" => "1\n", "weight" => 100}
          ]
        },
        inserted_at: now,
        updated_at: now
      }
    end)
  end)

blocks |> Enum.chunk_every(2000) |> Enum.each(fn batch -> Repo.insert_all(Block, batch) end)
IO.puts("Done.")

target_section = List.first(sections)
target_block = List.first(blocks)

IO.write("Generating #{students_count} accounts... ")
hashed_password = Argon2.hash_pwd_salt("Password123!")

students =
  Enum.map(1..students_count, fn i ->
    %{
      id: Ecto.UUID.generate(),
      login: "bot_#{suffix}_#{i}",
      password_hash: hashed_password,
      role_id: role.id,
      status: :active,
      inserted_at: now,
      updated_at: now
    }
  end)

students |> Enum.chunk_every(1000) |> Enum.each(fn batch -> Repo.insert_all(Account, batch) end)

memberships =
  Enum.map(students, fn student ->
    %{
      id: Ecto.UUID.generate(),
      account_id: student.id,
      cohort_id: cohort_id,
      inserted_at: now,
      updated_at: now
    }
  end)

memberships
|> Enum.chunk_every(1000)
|> Enum.each(fn batch -> Repo.insert_all(CohortMembership, batch) end)

IO.puts("Done.")

targets = %{
  course_id: course_id,
  sec_id: target_section.id,
  block_id: target_block.id,
  prefix: "bot_#{suffix}_",
  password: "Password123!"
}

File.write!("./targets.json", Jason.encode!(targets))

t1 = System.monotonic_time()
duration = System.convert_time_unit(t1 - t0, :native, :millisecond)

IO.puts("""
+-----------------------------------------------------------+
| SEED COMPLETED SUCCESSFULLY                               |
+-----------------------------------------------------------+
| Duration:        #{String.pad_trailing("#{duration} ms", 40)} |
| Login Prefix:    #{String.pad_trailing("bot_#{suffix}_*", 40)} |
| Course ID:       #{String.pad_trailing(course_id, 40)} |
| Cohort ID:       #{String.pad_trailing(cohort_id, 40)} |
| Target Sec ID:   #{String.pad_trailing(target_section.id, 40)} |
| Target Block ID: #{String.pad_trailing(target_block.id, 40)} |
| Configuration:   #{String.pad_trailing("targets.json updated", 40)} |
+-----------------------------------------------------------+
""")
