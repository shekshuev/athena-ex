defmodule Athena.Surveys.AnswerParams do
  @moduledoc """
  Turns the string-keyed, string-valued params a browser form sends into the
  typed `value` map `Athena.Surveys.SurveyAnswer` expects.

  Form params are always strings - `%{"number" => "4"}`, never `4` - and the
  answer changeset deliberately insists on real numbers, so that a malformed
  value is rejected rather than projected to `nil` and silently dropped from
  the statistics. Something has to bridge the two, and it lives here rather
  than in each caller because the builder's preview and the player both post
  the same shapes and must agree on them exactly: a preview that accepted a
  value the player rejects would be worse than no preview.

  Pure, so it can be tested as a table.

  Unparseable input is left out of the result rather than coerced. The
  changeset then reports it, which is the honest outcome: "4 apples" in a
  number field is a question to ask the respondent, not a 4.
  """

  alias Athena.Surveys.QuestionTypes

  @doc """
  Casts one question's form params into an answer `value` map.

  Accepts the params either bare (`%{"number" => "4"}`) or wrapped under
  `"value"`, which is how the rendered forms name their inputs.
  """
  @spec cast(QuestionTypes.t(), map()) :: map()
  def cast(type, %{"value" => value}) when is_map(value), do: cast(type, value)

  def cast(type, params) when is_map(params) do
    do_cast(type, params)
  end

  def cast(_type, _params), do: %{}

  defp do_cast(:single_choice, params) do
    %{}
    |> put_string(params, "choice_id")
    |> put_string(params, "other_text")
  end

  defp do_cast(:multiple_choice, params) do
    %{"choice_ids" => choice_list(params)}
    |> put_string(params, "other_text")
  end

  defp do_cast(:dichotomous, params), do: put_string(%{}, params, "choice_id")

  defp do_cast(:open_text, params) do
    # Not `put_string`: an empty textarea is a real, recorded empty answer,
    # distinct from never having been shown the question.
    case Map.get(params, "text") do
      text when is_binary(text) -> %{"text" => text}
      _ -> %{}
    end
  end

  defp do_cast(type, params) when type in [:numeric, :scale, :nps] do
    put_number(%{}, params, "number")
  end

  defp do_cast(:multi_scale, params) do
    %{}
    |> put_string(params, "row_id")
    |> put_number(params, "number")
  end

  defp do_cast(:matching, params) do
    case Map.get(params, "pairs") do
      pairs when is_map(pairs) ->
        %{
          "pairs" =>
            pairs
            |> Enum.reject(fn {_left, right} -> blank?(right) end)
            |> Map.new()
        }

      _ ->
        %{"pairs" => %{}}
    end
  end

  defp do_cast(:ranking, params), do: %{"choice_ids" => choice_list(params)}

  # A checkbox group sends nothing at all when every box is cleared, so the
  # rendered form carries a blank hidden input to keep the key present. That
  # blank is dropped here, which is what makes "unchecked everything" an
  # answered-but-empty row rather than a missing one.
  defp choice_list(params) do
    case Map.get(params, "choice_ids") do
      ids when is_list(ids) -> Enum.reject(ids, &blank?/1)
      id when is_binary(id) -> Enum.reject([id], &blank?/1)
      _ -> []
    end
  end

  defp put_string(acc, params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> Map.put(acc, key, value)
      _ -> acc
    end
  end

  defp put_number(acc, params, key) do
    case Map.get(params, key) do
      value when is_number(value) ->
        Map.put(acc, key, value)

      value when is_binary(value) ->
        case parse_number(value) do
          {:ok, number} -> Map.put(acc, key, number)
          :error -> acc
        end

      _ ->
        acc
    end
  end

  defp parse_number(string) do
    string = String.trim(string)

    case Integer.parse(string) do
      {integer, ""} ->
        {:ok, integer}

      _ ->
        case Float.parse(string) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
