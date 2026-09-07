# Seeds a demo course + 2 cohorts + 18 synthetic students (4 personas:
# excellent / average / slacker / struggling) with ~3 weeks of engagement
# history, for visually checking the engagement dashboard against known,
# intentional behavior patterns.
#
# Run against the dev database (MIX_ENV defaults to dev for `mix run`):
#
#     mix run priv/repo/seed_engagement_demo.exs
#
# Writes the created course/cohort/account ids to
# priv/repo/seed_engagement_demo_ids.json so seed_engagement_demo_cleanup.exs
# can remove exactly this data later.

defmodule EngagementDemoSeed do
  alias Athena.{Repo, Content, Learning, Engagement}
  alias Athena.Identity.{Accounts, Role}

  @teacher_login "demo_teacher_engagement"
  @password "DemoPass123!"

  def run do
    if Repo.get_by(Athena.Identity.Account, login: @teacher_login) do
      raise """
      #{@teacher_login} already exists - this script has already been run.
      Run priv/repo/seed_engagement_demo_cleanup.exs first if you want to
      reseed from scratch.
      """
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    teacher_role = Repo.get_by!(Role, name: "teacher")
    student_role = Repo.get_by!(Role, name: "student")

    teacher = create_account(@teacher_login, teacher_role.id)
    course = create_course(teacher)
    blocks = create_content(teacher, course)

    cohort_specs = [
      {:experimental, "[ДЕМО] Экспериментальная (авто-нудж)", true},
      {:control, "[ДЕМО] Контрольная (без вмешательства)", false}
    ]

    results =
      for {key, name, nudges_enabled} <- cohort_specs do
        cohort = create_cohort(teacher, name, nudges_enabled)
        {:ok, _enrollment} = Learning.enroll_cohort(teacher, cohort.id, course.id)

        students = create_students(student_role, key)

        Enum.each(students, fn {_persona, accounts} ->
          Enum.each(accounts, fn account ->
            {:ok, _membership} = Learning.add_student_to_cohort(teacher, cohort.id, account.id)
          end)
        end)

        seed_cohort_events(cohort, blocks, students, now)

        {key, %{cohort: cohort, students: students}}
      end
      |> Map.new()

    save_summary(teacher, course, results)
    print_summary(teacher, course, results)
  end

  # -- Accounts / course / content -----------------------------------------

  defp create_account(login, role_id) do
    {:ok, account} =
      Accounts.create_account(%{
        "login" => login,
        "password" => @password,
        "role_id" => role_id
      })

    Repo.preload(account, :role)
  end

  defp create_course(teacher) do
    {:ok, course} =
      Content.create_course(teacher, %{
        "title" => "[ДЕМО] Инженерия ПО — вовлечённость",
        "description" => "Синтетический курс для визуальной проверки дашборда вовлечённости.",
        "status" => "published",
        "type" => "standard"
      })

    course
  end

  defp create_content(teacher, course) do
    {:ok, sec_intro} =
      Content.create_section(teacher, %{
        "title" => "Введение",
        "course_id" => course.id,
        "order" => 10,
        "visibility" => "enrolled"
      })

    {:ok, sec_practice} =
      Content.create_section(teacher, %{
        "title" => "Практика",
        "course_id" => course.id,
        "order" => 20,
        "visibility" => "enrolled"
      })

    {:ok, sec_advanced} =
      Content.create_section(teacher, %{
        "title" => "Продвинутый модуль",
        "course_id" => course.id,
        "order" => 30,
        "visibility" => "enrolled"
      })

    {:ok, text1} =
      Content.create_block(teacher, %{
        "type" => "text",
        "section_id" => sec_intro.id,
        "order" => 10,
        "visibility" => "enrolled",
        "content" => %{"text" => "Введение в курс. Прочитайте внимательно перед тем как продолжить."},
        "engagement_rule" => %{"expected_seconds" => 300}
      })

    {:ok, quiz1} =
      Content.create_block(teacher, %{
        "type" => "quiz_question",
        "section_id" => sec_intro.id,
        "order" => 20,
        "visibility" => "enrolled",
        "content" => quiz_content("Что из перечисленного не является типом данных?"),
        "engagement_rule" => %{"expected_seconds" => 180}
      })

    {:ok, code} =
      Content.create_block(teacher, %{
        "type" => "code",
        "section_id" => sec_practice.id,
        "order" => 10,
        "visibility" => "enrolled",
        "content" => %{}
      })

    {:ok, text2} =
      Content.create_block(teacher, %{
        "type" => "text",
        "section_id" => sec_practice.id,
        "order" => 20,
        "visibility" => "enrolled",
        "content" => %{"text" => "Разбор решения предыдущей задачи и типичных ошибок."},
        "engagement_rule" => %{"expected_seconds" => 400}
      })

    {:ok, video} =
      Content.create_block(teacher, %{
        "type" => "video",
        "section_id" => sec_advanced.id,
        "order" => 10,
        "visibility" => "enrolled",
        "content" => %{"url" => "https://example.com/demo-lecture.mp4", "duration" => 600}
      })

    {:ok, quiz2} =
      Content.create_block(teacher, %{
        "type" => "quiz_question",
        "section_id" => sec_advanced.id,
        "order" => 20,
        "visibility" => "enrolled",
        "content" => quiz_content("Итоговый вопрос по продвинутому модулю."),
        "engagement_rule" => %{"expected_seconds" => 200}
      })

    %{
      sections: %{intro: sec_intro, practice: sec_practice, advanced: sec_advanced},
      text1: text1,
      quiz1: quiz1,
      code: code,
      text2: text2,
      video: video,
      quiz2: quiz2
    }
  end

  defp quiz_content(question_text) do
    %{
      "question_type" => "single",
      "answer_type" => "plain_text",
      "body" => %{"text" => question_text},
      "options" => [
        %{"id" => Ecto.UUID.generate(), "text" => %{"text" => "Вариант A"}, "is_correct" => true},
        %{"id" => Ecto.UUID.generate(), "text" => %{"text" => "Вариант B"}, "is_correct" => false},
        %{"id" => Ecto.UUID.generate(), "text" => %{"text" => "Вариант C"}, "is_correct" => false}
      ]
    }
  end

  defp create_cohort(teacher, name, nudges_enabled) do
    {:ok, cohort} =
      Learning.create_cohort(teacher, %{
        "name" => name,
        "type" => "academic",
        "nudges_enabled" => nudges_enabled
      })

    cohort
  end

  # -- Students --------------------------------------------------------------

  defp create_students(student_role, cohort_key) do
    %{
      excellent: create_persona_accounts(student_role, cohort_key, "excellent", 2),
      average: create_persona_accounts(student_role, cohort_key, "average", 3),
      slacker: create_persona_accounts(student_role, cohort_key, "slacker", 2),
      struggler: create_persona_accounts(student_role, cohort_key, "struggler", 2)
    }
  end

  defp create_persona_accounts(student_role, cohort_key, persona, count) do
    for n <- 1..count do
      login = "demo_#{cohort_key}_#{persona}_#{n}"
      create_account(login, student_role.id)
    end
  end

  # -- Event timeline ----------------------------------------------------------

  defp seed_cohort_events(cohort, blocks, students, now) do
    Enum.each(Enum.with_index(students.excellent), fn {account, i} ->
      seed_excellent(account, cohort.id, blocks, now, i)
    end)

    Enum.each(Enum.with_index(students.average), fn {account, i} ->
      seed_average(account, cohort.id, blocks, now, i)
    end)

    Enum.each(Enum.with_index(students.slacker), fn {account, i} ->
      seed_slacker(account, cohort.id, blocks, now, i)
    end)

    Enum.each(Enum.with_index(students.struggler), fn {account, i} ->
      seed_struggler(account, cohort.id, blocks, now, i)
    end)
  end

  # Fixed course-progression schedule shared by the "normal pace" personas -
  # later blocks happen on more recent days, with half the blocks inside the
  # default 7-day dashboard window and half further back (so the period
  # picker and weekly trend/heatmap actually have something to show).
  @schedule [text1: 20, quiz1: 15, code: 10, text2: 6, video: 3, quiz2: 1]

  defp at(now, day_offset, hour, minute \\ 0) do
    now
    |> DateTime.add(-day_offset * 86_400, :second)
    |> Map.merge(%{hour: hour, minute: minute, second: 0, microsecond: {0, 0}})
  end

  defp record(account_id, cohort_id, session_id, block, event_type, occurred_at, payload \\ %{}) do
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

  defp dwell(account_id, cohort_id, block, at, duration_seconds) do
    session = Ecto.UUID.generate()
    record(account_id, cohort_id, session, block, :viewport_enter, at)
    record(account_id, cohort_id, session, block, :viewport_exit, DateTime.add(at, duration_seconds, :second))
    session
  end

  defp complete(account_id, block_id) do
    {:ok, _} = Learning.mark_completed(account_id, block_id, nil)
  end

  # -- Отличник: steady pace, dwell ~= expected, full completion --------------

  defp seed_excellent(account, cohort_id, blocks, now, _i) do
    hour = 10

    dwell(account.id, cohort_id, blocks.text1, at(now, @schedule[:text1], hour), 300)
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.text1, :scroll_milestone, at(now, @schedule[:text1], hour), %{"percent" => 100})

    dwell(account.id, cohort_id, blocks.quiz1, at(now, @schedule[:quiz1], hour), 180)

    session = Ecto.UUID.generate()
    base = at(now, @schedule[:code], hour)
    record(account.id, cohort_id, session, blocks.code, :code_run_attempt, base)
    record(account.id, cohort_id, session, blocks.code, :code_run_attempt, DateTime.add(base, 180, :second))
    record(account.id, cohort_id, session, blocks.code, :code_run_result, DateTime.add(base, 185, :second), %{"outcome" => "accepted"})

    dwell(account.id, cohort_id, blocks.text2, at(now, @schedule[:text2], hour), 400)
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.text2, :scroll_milestone, at(now, @schedule[:text2], hour), %{"percent" => 100})

    video_session = Ecto.UUID.generate()
    video_at = at(now, @schedule[:video], hour)
    record(account.id, cohort_id, video_session, blocks.video, :video_play, video_at)
    record(account.id, cohort_id, video_session, blocks.video, :video_ended, DateTime.add(video_at, 600, :second), %{"duration" => 600})

    dwell(account.id, cohort_id, blocks.quiz2, at(now, @schedule[:quiz2], hour), 200)

    for block <- [blocks.text1, blocks.quiz1, blocks.code, blocks.text2, blocks.video, blocks.quiz2] do
      complete(account.id, block.id)
    end
  end

  # -- Средний: mostly fine, occasional slow dwell + hesitation + one backtrack

  defp seed_average(account, cohort_id, blocks, now, i) do
    hour = 14

    dwell(account.id, cohort_id, blocks.text1, at(now, @schedule[:text1], hour), 310)
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.text1, :scroll_milestone, at(now, @schedule[:text1], hour), %{"percent" => 100})

    dwell(account.id, cohort_id, blocks.quiz1, at(now, @schedule[:quiz1], hour), 190)
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.quiz1, :answer_changed, at(now, @schedule[:quiz1], hour, 3))

    # Practice section: slow dwell + a single code -> text -> code backtrack,
    # one session so it's attributed as one backtrack to the code block.
    practice_session = Ecto.UUID.generate()
    practice_at = at(now, @schedule[:code], hour)
    record(account.id, cohort_id, practice_session, blocks.code, :viewport_enter, practice_at)
    record(account.id, cohort_id, practice_session, blocks.code, :code_run_attempt, DateTime.add(practice_at, 60, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :viewport_exit, DateTime.add(practice_at, 850, :second))
    record(account.id, cohort_id, practice_session, blocks.text2, :viewport_enter, DateTime.add(practice_at, 900, :second))
    record(account.id, cohort_id, practice_session, blocks.text2, :viewport_exit, DateTime.add(practice_at, 1100, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :viewport_enter, DateTime.add(practice_at, 1150, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :code_run_result, DateTime.add(practice_at, 1200, :second), %{"outcome" => "accepted"})
    record(account.id, cohort_id, practice_session, blocks.code, :viewport_exit, DateTime.add(practice_at, 1210, :second))

    video_session = Ecto.UUID.generate()
    video_at = at(now, @schedule[:video], hour)
    record(account.id, cohort_id, video_session, blocks.video, :video_play, video_at)
    record(account.id, cohort_id, video_session, blocks.video, :video_ended, DateTime.add(video_at, 600, :second), %{"duration" => 600})

    completed_blocks =
      if i == 0 do
        [blocks.text1, blocks.quiz1, blocks.code, blocks.text2, blocks.video]
      else
        dwell(account.id, cohort_id, blocks.quiz2, at(now, @schedule[:quiz2], hour), 210)
        [blocks.text1, blocks.quiz1, blocks.code, blocks.text2, blocks.video, blocks.quiz2]
      end

    Enum.each(completed_blocks, &complete(account.id, &1.id))
  end

  # -- Халтурщик: fast dwell, shallow scroll, heavy paste, video skip,
  #    no debug cycle, all crammed into the last 2 nights - and the nudge
  #    never actually changes anything (same flags fire again afterward).

  defp seed_slacker(account, cohort_id, blocks, now, _i) do
    night1 = at(now, 1, 21)
    night2 = at(now, 0, 22)

    # Night 1: text1 (fast dwell + shallow scroll) and quiz1 (heavy paste).
    dwell(account.id, cohort_id, blocks.text1, night1, 6)
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.text1, :scroll_milestone, night1, %{"percent" => 40})
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.text1, :nudge_shown, DateTime.add(night1, 10, :second), %{"reason" => "fast_dwell"})

    dwell(account.id, cohort_id, blocks.quiz1, DateTime.add(night1, 300, :second), 8)
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.quiz1, :paste_detected, DateTime.add(night1, 305, :second), %{
      "pasted_chars" => 95,
      "total_chars" => 100
    })
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.quiz1, :nudge_shown, DateTime.add(night1, 315, :second), %{"reason" => "heavy_paste"})

    # Night 2: code (heavy paste, no run attempts -> no_debug_cycle), text2
    # (fast dwell again - the nudge from night 1 did not change anything),
    # video (skipped straight to the end), quiz2 (fast).
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.code, :paste_detected, night2, %{
      "pasted_chars" => 98,
      "total_chars" => 100
    })
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.code, :code_run_result, DateTime.add(night2, 5, :second), %{"outcome" => "accepted"})
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.code, :nudge_shown, DateTime.add(night2, 10, :second), %{"reason" => "heavy_paste"})

    dwell(account.id, cohort_id, blocks.text2, DateTime.add(night2, 300, :second), 8)
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.text2, :scroll_milestone, DateTime.add(night2, 300, :second), %{"percent" => 30})
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.text2, :nudge_shown, DateTime.add(night2, 310, :second), %{"reason" => "fast_dwell"})

    video_at = DateTime.add(night2, 600, :second)
    video_session = Ecto.UUID.generate()
    record(account.id, cohort_id, video_session, blocks.video, :video_play, video_at)
    record(account.id, cohort_id, video_session, blocks.video, :video_seek, DateTime.add(video_at, 10, :second), %{"from_sec" => 10, "to_sec" => 590})
    record(account.id, cohort_id, video_session, blocks.video, :video_ended, DateTime.add(video_at, 15, :second), %{"duration" => 600})
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.video, :nudge_shown, DateTime.add(video_at, 20, :second), %{"reason" => "video_skipped"})

    dwell(account.id, cohort_id, blocks.quiz2, DateTime.add(night2, 900, :second), 7)

    for block <- [blocks.text1, blocks.quiz1, blocks.code, blocks.text2, blocks.video, blocks.quiz2] do
      complete(account.id, block.id)
    end
  end

  # -- Отстающий: slow dwell, hesitation, panic debugging, a real
  #    code -> text -> code backtrack (shared by both students of this
  #    persona, so the section itself gets flagged, not just the student).

  defp seed_struggler(account, cohort_id, blocks, now, i) do
    hour = 16

    dwell(account.id, cohort_id, blocks.text1, at(now, @schedule[:text1], hour), 320)
    dwell(account.id, cohort_id, blocks.quiz1, at(now, @schedule[:quiz1], hour), 190)
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.quiz1, :answer_changed, at(now, @schedule[:quiz1], hour, 2))
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.quiz1, :answer_changed, at(now, @schedule[:quiz1], hour, 4))
    record(account.id, cohort_id, Ecto.UUID.generate(), blocks.quiz1, :answer_changed, at(now, @schedule[:quiz1], hour, 6))

    # Practice: slow dwell + panic debugging + code -> text -> code backtrack,
    # all in one session.
    practice_session = Ecto.UUID.generate()
    practice_at = at(now, @schedule[:code], hour)
    record(account.id, cohort_id, practice_session, blocks.code, :viewport_enter, practice_at)
    record(account.id, cohort_id, practice_session, blocks.code, :code_run_attempt, DateTime.add(practice_at, 30, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :code_run_attempt, DateTime.add(practice_at, 35, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :code_run_attempt, DateTime.add(practice_at, 39, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :code_run_attempt, DateTime.add(practice_at, 42, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :viewport_exit, DateTime.add(practice_at, 1300, :second))
    record(account.id, cohort_id, practice_session, blocks.text2, :viewport_enter, DateTime.add(practice_at, 1350, :second))
    record(account.id, cohort_id, practice_session, blocks.text2, :viewport_exit, DateTime.add(practice_at, 1900, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :viewport_enter, DateTime.add(practice_at, 1950, :second))
    record(account.id, cohort_id, practice_session, blocks.code, :code_run_result, DateTime.add(practice_at, 2100, :second), %{"outcome" => "accepted"})
    record(account.id, cohort_id, practice_session, blocks.code, :viewport_exit, DateTime.add(practice_at, 2110, :second))

    video_session = Ecto.UUID.generate()
    video_at = at(now, @schedule[:video], hour)
    record(account.id, cohort_id, video_session, blocks.video, :video_play, video_at)
    record(account.id, cohort_id, video_session, blocks.video, :video_ended, DateTime.add(video_at, 640, :second), %{"duration" => 600})

    dwell(account.id, cohort_id, blocks.quiz2, at(now, @schedule[:quiz2], hour), 260)

    completed_blocks =
      if i == 0 do
        [blocks.text1, blocks.quiz1, blocks.video, blocks.quiz2]
      else
        [blocks.text1, blocks.quiz1, blocks.code, blocks.text2, blocks.video, blocks.quiz2]
      end

    Enum.each(completed_blocks, &complete(account.id, &1.id))
  end

  # -- Summary / ids file ------------------------------------------------------

  defp save_summary(teacher, course, results) do
    data = %{
      "teacher_account_id" => teacher.id,
      "course_id" => course.id,
      "cohorts" =>
        Map.new(results, fn {key, %{cohort: cohort, students: students}} ->
          {to_string(key),
           %{
             "cohort_id" => cohort.id,
             "student_account_ids" =>
               students
               |> Map.values()
               |> List.flatten()
               |> Enum.map(& &1.id)
           }}
        end)
    }

    path = Path.join(__DIR__, "seed_engagement_demo_ids.json")
    File.write!(path, Jason.encode!(data, pretty: true))
    IO.puts("\nSaved ids to #{path}")
  end

  defp print_summary(teacher, course, results) do
    IO.puts("\n=== Готово ===")
    IO.puts("Курс: #{course.title} (id: #{course.id})")
    IO.puts("Владелец (teacher): #{teacher.login} / #{@password}")

    for {key, %{cohort: cohort}} <- results do
      IO.puts("\nКогорта [#{key}]: #{cohort.name} (id: #{cohort.id})")
      IO.puts("  http://localhost:4000/teaching/cohorts/#{cohort.id}/engagement/#{course.id}")
      IO.puts("  http://localhost:4000/teaching/cohorts/#{cohort.id}/engagement/#{course.id}?view=students")
    end

    IO.puts("\nСравнение когорт:")
    IO.puts("  http://localhost:4000/teaching/courses/#{course.id}/engagement/compare")
  end
end

EngagementDemoSeed.run()
