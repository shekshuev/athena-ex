defmodule Athena.Gamification.RuleEngine do
  @moduledoc """
  Tiny interpreter for the badge rule-DSL — a JSON-shaped boolean
  expression tree over `Athena.Gamification.Facts` (see
  `Athena.Gamification.Badge` for the grammar). Not a text/grammar parser:
  the rule is already a data structure (decoded JSON), so evaluation is a
  plain recursive walk.
  """
  alias Athena.Gamification.Facts

  @operators ~w(gte lte gt lt eq ne)

  @doc """
  Evaluates a rule tree for one account.
  """
  @spec evaluate(map(), String.t()) :: boolean()
  def evaluate(%{"and" => conditions}, account_id) when is_list(conditions) do
    Enum.all?(conditions, &evaluate(&1, account_id))
  end

  def evaluate(%{"or" => conditions}, account_id) when is_list(conditions) do
    Enum.any?(conditions, &evaluate(&1, account_id))
  end

  def evaluate(%{"not" => condition}, account_id) when is_map(condition) do
    not evaluate(condition, account_id)
  end

  def evaluate(%{"fact" => fact_name, "op" => op, "value" => value} = leaf, account_id)
      when is_binary(fact_name) and op in @operators do
    args = Map.get(leaf, "args", %{})
    actual = Facts.value(fact_name, args, account_id)
    compare(op, actual, value)
  end

  def evaluate(_invalid, _account_id), do: false

  @doc """
  Structurally validates a rule tree before it's saved: known facts and
  operators, well-formed nesting. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(%{"and" => conditions}) when is_list(conditions) and conditions != [],
    do: validate_all(conditions)

  def validate(%{"and" => _}), do: {:error, "\"and\" must be a non-empty list of conditions"}

  def validate(%{"or" => conditions}) when is_list(conditions) and conditions != [],
    do: validate_all(conditions)

  def validate(%{"or" => _}), do: {:error, "\"or\" must be a non-empty list of conditions"}

  def validate(%{"not" => condition}) when is_map(condition), do: validate(condition)
  def validate(%{"not" => _}), do: {:error, "\"not\" must wrap a single condition"}

  def validate(%{"fact" => fact_name, "op" => op, "value" => value} = leaf)
      when is_binary(fact_name) and is_number(value) do
    cond do
      fact_name not in Facts.known_facts() ->
        {:error, "unknown fact #{inspect(fact_name)}"}

      op not in @operators ->
        {:error, "unknown operator #{inspect(op)}"}

      not is_map(Map.get(leaf, "args", %{})) ->
        {:error, "\"args\" must be an object"}

      true ->
        :ok
    end
  end

  def validate(_invalid), do: {:error, "must be a fact leaf or and/or/not combinator"}

  defp validate_all(conditions) do
    Enum.find_value(conditions, :ok, fn condition ->
      case validate(condition) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp compare("gte", a, b), do: a >= b
  defp compare("lte", a, b), do: a <= b
  defp compare("gt", a, b), do: a > b
  defp compare("lt", a, b), do: a < b
  defp compare("eq", a, b), do: a == b
  defp compare("ne", a, b), do: a != b
end
