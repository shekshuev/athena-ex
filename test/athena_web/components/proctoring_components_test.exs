defmodule AthenaWeb.ProctoringComponentsTest do
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias AthenaWeb.ProctoringComponents

  @start ~U[2026-11-22 10:00:00Z]

  defp timeline(locale) do
    Athena.TimeZones.put_user_timezone("Europe/Moscow")

    entry = %{
      type: :copy_attempt,
      offset: 3905,
      count: 1,
      at: DateTime.add(@start, 3905, :second),
      started_at: @start
    }

    Gettext.with_locale(AthenaWeb.Gettext, locale, fn ->
      render_component(&ProctoringComponents.submission_breakdown_modal/1,
        show: true,
        tab: "timeline",
        content: %{"risk_level" => "green", "scoring_version" => 2},
        timeline: [entry]
      )
    end)
    |> LazyHTML.from_fragment()
  end

  test "history names its origin and shows hours and an unambiguous zoned clock" do
    doc = timeline("en")
    origin = doc |> LazyHTML.query("#proctoring-timeline-origin") |> LazyHTML.text()
    assert origin =~ "22.11.2026 13:00:00"
    assert origin =~ "Europe/Moscow"
    assert origin =~ "+HH:MM:SS"
    event = doc |> LazyHTML.query("#proctoring-event-0") |> LazyHTML.text()
    assert event =~ "+01:05:05"
    assert event =~ "22.11.2026 14:05:05"
    assert event =~ "Copied question text"

    assert Enum.count(
             LazyHTML.query(doc, "#proctoring-event-0 time[datetime='2026-11-22T11:05:05Z']")
           ) == 1
  end

  test "Russian event history explains time and ordinary clipboard actions" do
    doc = timeline("ru")

    assert doc |> LazyHTML.query("#proctoring-timeline-origin") |> LazyHTML.text() =~
             "Начало попытки:"

    assert doc |> LazyHTML.query("#proctoring-timeline-origin") |> LazyHTML.text() =~ "+ЧЧ:ММ:СС"

    assert doc |> LazyHTML.query("#proctoring-event-0") |> LazyHTML.text() =~
             "Копирование текста вопроса"

    assert doc |> LazyHTML.query("#proctoring-detail-modal") |> LazyHTML.text() =~
             "Запись события не подтверждает нарушение"
  end

  test "Russian methodology and priority labels do not accuse the student" do
    doc =
      Gettext.with_locale(AthenaWeb.Gettext, "ru", fn ->
        render_component(&ProctoringComponents.methodology_modal/1, show: true)
      end)
      |> LazyHTML.from_fragment()

    text = doc |> LazyHTML.query("#proctoring-methodology") |> LazyHTML.text()
    assert text =~ "не блокирует ответы"
    assert text =~ "не подтверждённое нарушение"
    assert text =~ "без баллов"
    assert text =~ "10 с"

    for {colour, label} <- [
          {"green", "Нет признаков с баллами"},
          {"yellow", "Рекомендуется проверить"},
          {"red", "Проверить в первую очередь"}
        ] do
      badge =
        Gettext.with_locale(AthenaWeb.Gettext, "ru", fn ->
          render_component(&ProctoringComponents.risk_badge/1, content: %{"risk_level" => colour})
        end)
        |> LazyHTML.from_fragment()

      assert badge |> LazyHTML.query(".proctoring-risk-badge") |> LazyHTML.text() =~ label
    end
  end
end
