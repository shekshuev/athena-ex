defmodule Athena.Content.LibraryExport do
  @moduledoc """
  Exports readable, individual library questions. Assessments and other block
  types are counted in the preview but never expanded or converted to questions.
  """
  import Ecto.Query

  alias Athena.Content.{Library, QuestionExport}
  alias Athena.Repo

  def preview(user, params) do
    with {:ok, query} <- Library.export_query(user, params) do
      counts =
        query
        |> exclude(:preload)
        |> exclude(:order_by)
        |> group_by([lb], lb.type)
        |> select([lb], {lb.type, count(lb.id)})
        |> Repo.all()
        |> Map.new()

      total = counts |> Map.values() |> Enum.sum()
      questions = Map.get(counts, :quiz_question, 0)
      {:ok, %{total: total, questions: questions, skipped: total - questions}}
    end
  end

  def download(user, params, format, opts \\ [])

  def download(user, params, format, opts) when format in ["gift", "moodle_xml"] do
    with {:ok, query} <- Library.export_query(user, params),
         [_ | _] = blocks <-
           Repo.all(query |> exclude(:preload) |> where([lb], lb.type == :quiz_question)),
         {:ok, body} <- QuestionExport.encode(blocks, format, opts) do
      {filename, content_type} =
        case format do
          "gift" -> {"library_questions.gift.txt", "text/plain"}
          "moodle_xml" -> {"library_questions.moodle.xml", "application/xml"}
        end

      {:ok, %{body: body, filename: filename, content_type: content_type}}
    else
      [] -> {:error, :no_questions}
      {:error, _} = error -> error
    end
  end

  def download(_user, _params, _format, _opts), do: {:error, :invalid_format}
end
