defmodule AthenaWeb.SqlExecutionTranslationsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias AthenaWeb.BlockComponents

  test "SQL errors do not claim to be PostgreSQL errors for another engine" do
    document =
      render_result(%{
        "type" => "sql_state",
        "status" => "sql_error",
        "stderr" => "ClickHouse: ACCESS_DENIED"
      })

    title = document |> LazyHTML.query("[role='alert'] > div") |> LazyHTML.text()
    assert title =~ "Ошибка SQL"
    refute title =~ "PostgreSQL"
  end

  test "query verdicts are translated" do
    for {status, translation} <- [{"accepted", "Принято"}, {"wrong_answer", "Неверный ответ"}] do
      document =
        render_result(%{"type" => "sql_query", "status" => status, "columns" => [], "rows" => []})

      assert document |> LazyHTML.query(".badge") |> LazyHTML.text() |> String.trim() ==
               translation
    end
  end

  test "successful state verification uses its translation even with the runner's English message" do
    document =
      render_result(%{
        "type" => "sql_state",
        "status" => "accepted",
        "message" => "State verification passed."
      })

    assert LazyHTML.text(document) =~ "Проверка состояния пройдена"
    refute LazyHTML.text(document) =~ "State verification passed."
  end

  defp render_result(payload) do
    block = %Athena.Content.Block{
      id: Ecto.UUID.generate(),
      type: :code,
      content: %{"language" => "sql", "database_engine" => "clickhouse"}
    }

    draft = %{"execution_results" => [%{"stdout" => Jason.encode!(payload)}]}

    Gettext.with_locale(AthenaWeb.Gettext, "ru", fn ->
      render_component(&BlockComponents.content_block/1,
        block: block,
        mode: :review,
        draft: draft
      )
    end)
    |> LazyHTML.from_fragment()
  end
end
