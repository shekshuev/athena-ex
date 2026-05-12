import Ecto.Query, warn: false
alias Athena.Repo
alias Athena.Content.{Course, Section, Block}
alias Athena.Learning.Submission
alias Athena.Learning
alias Athena.Identity.{Account, Role}
alias Phoenix.PubSub

Logger.configure(level: :warning)

concurrency = 100
total_requests = 1000

{os_fam, os_name} = :os.type()
cores = System.schedulers_online()

suffix = :erlang.unique_integer([:positive])
role = Repo.all(Role) |> List.first()
admin = Repo.all(Account) |> List.first()

course = Repo.insert!(%Course{title: "STRESS-#{suffix}", status: :published, owner_id: admin.id})

section =
  Repo.insert!(%Section{
    title: "S1",
    order: 0,
    course_id: course.id,
    path: %EctoLtree.LabelTree{labels: ["bench#{suffix}"]}
  })

block =
  Repo.insert!(%Block{
    section_id: section.id,
    type: :code,
    content: %{
      "language" => "python3",
      "test_cases" => [
        %{"id" => "tc1", "input" => "1", "expected_output" => "1\n", "weight" => 100}
      ]
    }
  })

IO.write("Creating students accounts... ")

students =
  Enum.map(1..total_requests, fn i ->
    Repo.insert!(%Account{login: "st-#{suffix}-#{i}", password_hash: "noop", role_id: role.id})
  end)

IO.puts("Done.")

IO.puts("\nTest started: #{total_requests} requests...")

simulate = fn student ->
  t0 = System.monotonic_time()
  topic = "submission:#{student.id}:#{block.id}"
  PubSub.subscribe(Athena.PubSub, topic)

  sub_attrs = %{
    "block_id" => block.id,
    "status" => :pending,
    "content" => %{"type" => :code, "code" => "print(1)"}
  }

  case Learning.create_submission(student, sub_attrs) do
    {:ok, sub} ->
      IO.write(".")
      target_sub_id = sub.id

      fn_wait = fn recursive_wait ->
        receive do
          {:submission_updated, %{id: ^target_sub_id, status: raw_status}} ->
            status = to_string(raw_status)

            cond do
              status == "processing" ->
                recursive_wait.(recursive_wait)

              status in ["accepted", "wrong_answer", "runtime_error", "time_limit_exceeded"] ->
                t1 = System.monotonic_time()

                %{
                  status: String.to_atom(status),
                  duration: System.convert_time_unit(t1 - t0, :native, :millisecond)
                }

              true ->
                recursive_wait.(recursive_wait)
            end

          _other_msg ->
            recursive_wait.(recursive_wait)
        after
          60_000 -> %{status: :timeout, duration: 60_000}
        end
      end

      fn_wait.(fn_wait)

    {:error, _} ->
      %{status: :error, duration: 0}
  end
end

start_bench = System.monotonic_time()

results =
  students
  |> Task.async_stream(simulate, max_concurrency: concurrency, timeout: :infinity)
  |> Enum.map(fn {:ok, res} -> res end)

end_bench = System.monotonic_time()
total_ms = System.convert_time_unit(end_bench - start_bench, :native, :millisecond)

durations = Enum.map(results, & &1.duration) |> Enum.sort()
successes = Enum.count(results, &(&1.status == :accepted))
avg = if length(durations) > 0, do: Enum.sum(durations) / length(durations), else: 0
tps = (total_requests / (total_ms / 1000)) |> Float.round(2)

throughput_str = "#{tps} req/sec"
avg_lat_str = "#{Float.round(avg, 2)} ms"

p95_val =
  if length(durations) > 0, do: Enum.at(durations, round(length(durations) * 0.95) - 1), else: 0

p95_lat_str = "#{p95_val} ms"
accepted_str = "#{successes} / #{total_requests}"

IO.puts("""
\n
+-----------------------------------------------------------+
| SYSTEM INFO                                               |
+-----------------------------------------------------------+
| OS:            #{String.pad_trailing("#{os_fam} #{os_name}", 42)} |
| Cores:         #{String.pad_trailing("#{cores}", 42)} |
+-----------------------------------------------------------+
| ATHENA ENGINE FINAL REPORT                                |
+-----------------------------------------------------------+
| Throughput:    #{String.pad_trailing(throughput_str, 42)} |
| Avg Latency:   #{String.pad_trailing(avg_lat_str, 42)} |
| P95 Latency:   #{String.pad_trailing(p95_lat_str, 42)} |
+-----------------------------------------------------------+
| Accepted Rate: #{String.pad_trailing(accepted_str, 42)} |
+-----------------------------------------------------------+
""")

IO.puts("Cleaning DB...")
Repo.delete_all(from(s in Submission, where: s.block_id == ^block.id))
Enum.each(students, &Repo.delete!(&1))
Repo.delete!(block)
Repo.delete!(section)
Repo.delete!(course)
IO.puts("Cleaning done.")
