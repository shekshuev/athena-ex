defmodule Athena.Surveys.Flow do
  @moduledoc """
  The branching engine: given a survey's questions, its rules and the answers
  so far, decides what the respondent sees next.

  Pure - no `Repo`, no side effects. `Athena.Surveys.load_flow/1` does the
  loading and hands the result here. That split is what lets the builder's
  preview walk a branch entirely in socket assigns, writing nothing, while
  the player runs the same code against real rows: one implementation of the
  logic, exercised twice.

  ## How a step is decided

  Rules hang off the question just answered and are evaluated in `position`
  order; **the first match wins**, so an author puts specific rules above
  general ones. If nothing matches, the respondent falls through to the next
  question in document order. A survey with no rules is therefore a plain
  linear walk, with no special case.

  Because the fall-through edge always exists (a rule must have a condition,
  so no rule is unconditional), every question stays reachable. That is why
  `validate_graph/1` reports backward targets, cycles and dangling references
  but not "unreachable question" - with dense positions the check could never
  fire, and a check that cannot fail is worse than no check.

  ## Conditions read the projections, not the raw value

  A clause is evaluated against `Athena.Surveys.SurveyAnswer`'s typed
  projections (`value_numeric`, `value_choice_ids`, `value_text`), never
  against the raw `value` map. So the comparison a rule performs is exactly
  the one the statistics layer performs, and a question type whose answers
  aggregate correctly also branches correctly.

  A clause whose operand does not fit the answer it is testing - a numeric
  comparison against a free-text answer, say - is **false**, never true. A
  misconfigured rule must not quietly reroute everyone, and `:neq` in
  particular is not simply "not equal": an incomparable pair is false for
  both `:eq` and `:neq`.

  ## Operators

    * `:eq`, `:neq` - exact: number equality, text equality, or choice-set
      equality. For a multi-select, `:eq` means the respondent chose exactly
      that set.
    * `:gt`, `:gte`, `:lt`, `:lte`, `:between` - numeric only (`:between` is
      inclusive, `%{"from" => a, "to" => b}`).
    * `:in`, `:not_in` - overlap: true when any of the respondent's choices is
      in the clause's list, or when a number or text is among the listed
      values. For a single-choice question, which is the common case, this
      reads as "the answer is one of these".
    * `:contains_any`, `:contains_all` - the subset operators for
      multi-select answers.
    * `:answered`, `:not_answered` - presence. A deliberately skipped answer
      counts as *not* answered, which is what an author means by it.

  A clause on a `:multi_scale` question must name the matrix row it tests, as
  `"row_id"` in the clause value - a matrix stores one answer per row, so
  "the answer to this question" is not a single thing. A clause that omits it
  cannot be evaluated, is false, and is reported by `validate_graph/1`.
  """

  alias Athena.Surveys.{BranchClause, Survey, SurveyAnswer, SurveyBranch, SurveyQuestion}

  @enforce_keys [:survey, :questions, :branches, :by_id, :by_position]
  defstruct [:survey, :questions, :branches, :by_id, :by_position]

  @type t :: %__MODULE__{
          survey: Survey.t(),
          questions: [SurveyQuestion.t()],
          branches: %{binary() => [SurveyBranch.t()]},
          by_id: %{binary() => SurveyQuestion.t()},
          by_position: %{integer() => SurveyQuestion.t()}
        }

  @type step :: {:question, SurveyQuestion.t()} | :end
  @type answers :: %{{binary(), String.t()} => SurveyAnswer.t()}

  @doc """
  Assembles a flow from already-loaded data. Questions are sorted here rather
  than trusted to arrive in order, since a caller holding them in socket
  assigns may have appended one.
  """
  @spec build(Survey.t(), [SurveyQuestion.t()], [SurveyBranch.t()]) :: t()
  def build(%Survey{} = survey, questions, branches) do
    sorted = Enum.sort_by(questions, & &1.position)

    %__MODULE__{
      survey: survey,
      questions: sorted,
      branches:
        branches
        |> Enum.group_by(& &1.question_id)
        |> Map.new(fn {id, rules} -> {id, Enum.sort_by(rules, & &1.position)} end),
      by_id: Map.new(sorted, &{&1.id, &1}),
      by_position: Map.new(sorted, &{&1.position, &1})
    }
  end

  @doc "The question a respondent starts on, or `nil` for an empty survey."
  @spec first_question(t()) :: SurveyQuestion.t() | nil
  def first_question(%__MODULE__{questions: []}), do: nil
  def first_question(%__MODULE__{questions: [first | _]}), do: first

  @doc "Looks a question up by id."
  @spec question(t(), binary() | nil) :: SurveyQuestion.t() | nil
  def question(%__MODULE__{}, nil), do: nil
  def question(%__MODULE__{by_id: by_id}, id), do: Map.get(by_id, id)

  @doc "The questions on one page, in order."
  @spec questions_on_page(t(), integer()) :: [SurveyQuestion.t()]
  def questions_on_page(%__MODULE__{questions: questions}, page) do
    Enum.filter(questions, &(&1.page == page))
  end

  @doc "Every page number that has at least one question, in order."
  @spec pages(t()) :: [integer()]
  def pages(%__MODULE__{questions: questions}) do
    questions |> Enum.map(& &1.page) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  The step after `current` given `answers`: the next question, or `:end` when
  the survey is over.
  """
  @spec next_question(t(), SurveyQuestion.t() | binary(), answers()) :: step()
  def next_question(flow, current, answers) when is_binary(current) do
    case question(flow, current) do
      nil -> :end
      found -> next_question(flow, found, answers)
    end
  end

  def next_question(%__MODULE__{} = flow, %SurveyQuestion{} = current, answers) do
    case matching_branch(flow, current, answers) do
      nil -> fall_through(flow, current)
      branch -> apply_action(flow, current, branch)
    end
  end

  @doc """
  The page after `page`, for a `:by_page` survey.

  Rules on *any* question of the current page are considered, in page order
  then rule order, and the first match wins - a page is answered as a whole,
  so a rule on its second question is as entitled to redirect as one on its
  first.
  """
  @spec next_page(t(), integer(), answers()) :: {:page, integer()} | :end
  def next_page(%__MODULE__{} = flow, page, answers) do
    flow
    |> questions_on_page(page)
    |> Enum.find_value(fn question ->
      case matching_branch(flow, question, answers) do
        nil -> nil
        branch -> page_of_step(apply_action(flow, question, branch))
      end
    end)
    |> case do
      nil -> next_sequential_page(flow, page)
      step -> step
    end
  end

  defp page_of_step(:end), do: :end
  defp page_of_step({:question, question}), do: {:page, question.page}

  defp next_sequential_page(flow, page) do
    case Enum.find(pages(flow), &(&1 > page)) do
      nil -> :end
      next -> {:page, next}
    end
  end

  @doc """
  Steps back through `history` - the ids of the questions already visited,
  most recent first.

  Branching makes "the previous question" uncomputable from the current one:
  several paths can arrive at the same question, so the only truthful answer
  is the one the respondent actually took. Hence the explicit history rather
  than arithmetic on `position`.

  Returns `:none` when there is nowhere to go back to, or when the survey
  disallows it - keeping that rule here means the player cannot forget it.
  """
  @spec previous(t(), [binary()]) :: {:question, SurveyQuestion.t(), [binary()]} | :none
  def previous(%__MODULE__{survey: %Survey{settings: %{allow_back: false}}}, _history), do: :none

  def previous(%__MODULE__{} = flow, history) do
    history
    |> Enum.drop_while(&is_nil(question(flow, &1)))
    |> case do
      [] -> :none
      [id | rest] -> {:question, question(flow, id), rest}
    end
  end

  @doc """
  The questions a respondent with these `answers` actually walks through.

  Used for the progress indicator ("3 of 7" has to count the path taken, not
  the whole survey), for the builder preview, and by `Results` to tell
  "nobody answered this" apart from "nobody was asked this".

  Guards against cycles: a survey whose rules loop is reported by
  `validate_graph/1`, but this must still terminate rather than hang the
  player.
  """
  @spec visible_questions(t(), answers()) :: [SurveyQuestion.t()]
  def visible_questions(%__MODULE__{} = flow, answers \\ %{}) do
    case first_question(flow) do
      nil -> []
      first -> walk(flow, first, answers, [], MapSet.new())
    end
  end

  defp walk(flow, %SurveyQuestion{} = question, answers, acc, seen) do
    if MapSet.member?(seen, question.id) do
      Enum.reverse(acc)
    else
      acc = [question | acc]
      seen = MapSet.put(seen, question.id)

      case next_question(flow, question, answers) do
        :end -> Enum.reverse(acc)
        {:question, next} -> walk(flow, next, answers, acc, seen)
      end
    end
  end

  # -- rule evaluation ------------------------------------------------------

  defp matching_branch(%__MODULE__{branches: branches}, %SurveyQuestion{id: id}, answers) do
    branches
    |> Map.get(id, [])
    |> Enum.find(&condition_met?(&1.condition, answers))
  end

  @doc """
  Whether a condition holds for these answers. Exposed because the logic
  editor previews a rule against sample answers.
  """
  @spec condition_met?(map() | nil, answers()) :: boolean()
  def condition_met?(nil, _answers), do: false

  def condition_met?(%{clauses: []}, _answers), do: false

  def condition_met?(%{logic: :and, clauses: clauses}, answers),
    do: Enum.all?(clauses, &clause_met?(&1, answers))

  def condition_met?(%{logic: :or, clauses: clauses}, answers),
    do: Enum.any?(clauses, &clause_met?(&1, answers))

  defp clause_met?(clause, answers) do
    answer = fetch_answer(answers, clause)

    case clause.op do
      :answered -> answered?(answer)
      :not_answered -> not answered?(answer)
      op -> answered?(answer) and compare(op, clause.value || %{}, answer) == true
    end
  end

  # A matrix question stores one answer per row, so a clause testing one must
  # say which row. Without `row_id` there is nothing to fetch, and the clause
  # is false rather than accidentally matching some arbitrary row.
  defp fetch_answer(answers, clause) do
    row_key = Map.get(clause.value || %{}, "row_id", "")
    Map.get(answers, {clause.question_id, row_key})
  end

  defp answered?(nil), do: false
  defp answered?(%SurveyAnswer{skipped: true}), do: false
  defp answered?(%SurveyAnswer{}), do: true

  # Returns `true`, `false`, or `:incomparable` for an operand that does not
  # fit the answer. `:incomparable` is deliberately not `false`-by-negation:
  # see the moduledoc on `:neq`.
  defp compare(:eq, operand, answer), do: equality(operand, answer)

  defp compare(:neq, operand, answer) do
    case equality(operand, answer) do
      :incomparable -> :incomparable
      result -> not result
    end
  end

  defp compare(op, operand, answer) when op in [:gt, :gte, :lt, :lte] do
    with {:ok, expected} <- number(operand, "number"),
         {:ok, actual} <- answer_number(answer) do
      case op do
        :gt -> actual > expected
        :gte -> actual >= expected
        :lt -> actual < expected
        :lte -> actual <= expected
      end
    else
      :error -> :incomparable
    end
  end

  defp compare(:between, operand, answer) do
    with {:ok, from} <- number(operand, "from"),
         {:ok, to} <- number(operand, "to"),
         {:ok, actual} <- answer_number(answer) do
      actual >= from and actual <= to
    else
      :error -> :incomparable
    end
  end

  defp compare(:in, operand, answer), do: overlap(operand, answer)

  defp compare(:not_in, operand, answer) do
    case overlap(operand, answer) do
      :incomparable -> :incomparable
      result -> not result
    end
  end

  defp compare(:contains_any, operand, answer) do
    with {:ok, expected} <- choice_set(operand),
         {:ok, actual} <- answer_choice_set(answer) do
      not MapSet.disjoint?(expected, actual)
    else
      :error -> :incomparable
    end
  end

  defp compare(:contains_all, operand, answer) do
    with {:ok, expected} <- choice_set(operand),
         {:ok, actual} <- answer_choice_set(answer) do
      MapSet.subset?(expected, actual)
    else
      :error -> :incomparable
    end
  end

  defp equality(operand, answer) do
    cond do
      Map.has_key?(operand, "number") -> numeric_equality(operand, answer)
      Map.has_key?(operand, "choice_ids") -> choice_equality(operand, answer)
      Map.has_key?(operand, "text") -> text_equality(operand, answer)
      true -> :incomparable
    end
  end

  defp numeric_equality(operand, answer) do
    with {:ok, expected} <- number(operand, "number"),
         {:ok, actual} <- answer_number(answer) do
      actual == expected
    else
      :error -> :incomparable
    end
  end

  defp choice_equality(operand, answer) do
    with {:ok, expected} <- choice_set(operand),
         {:ok, actual} <- answer_choice_set(answer) do
      MapSet.equal?(expected, actual)
    else
      :error -> :incomparable
    end
  end

  defp text_equality(operand, answer) do
    case {Map.get(operand, "text"), answer.value_text} do
      {expected, actual} when is_binary(expected) and is_binary(actual) -> actual == expected
      _ -> :incomparable
    end
  end

  # `:in` / `:not_in` as overlap, which is what an author means for the
  # single-choice case and still defined for a multi-select.
  defp overlap(operand, answer) do
    cond do
      Map.has_key?(operand, "choice_ids") ->
        compare(:contains_any, operand, answer)

      Map.has_key?(operand, "numbers") ->
        with {:ok, actual} <- answer_number(answer),
             numbers when is_list(numbers) <- Map.get(operand, "numbers") do
          Enum.any?(numbers, &(is_number(&1) and &1 / 1 == actual))
        else
          _ -> :incomparable
        end

      Map.has_key?(operand, "texts") ->
        case {Map.get(operand, "texts"), answer.value_text} do
          {texts, actual} when is_list(texts) and is_binary(actual) -> actual in texts
          _ -> :incomparable
        end

      true ->
        :incomparable
    end
  end

  defp number(operand, key) do
    case Map.get(operand, key) do
      n when is_number(n) -> {:ok, n / 1}
      _ -> :error
    end
  end

  defp answer_number(%SurveyAnswer{value_numeric: n}) when is_number(n), do: {:ok, n / 1}
  defp answer_number(%SurveyAnswer{}), do: :error

  defp choice_set(operand) do
    case Map.get(operand, "choice_ids") do
      ids when is_list(ids) -> {:ok, MapSet.new(ids)}
      _ -> :error
    end
  end

  defp answer_choice_set(%SurveyAnswer{value_choice_ids: ids}) when is_list(ids),
    do: {:ok, MapSet.new(ids)}

  defp answer_choice_set(%SurveyAnswer{}), do: :error

  # -- actions --------------------------------------------------------------

  defp apply_action(flow, current, %SurveyBranch{action: :goto_question} = branch) do
    case question(flow, branch.target_question_id) do
      # A target deleted out from under the rule must not strand the
      # respondent: fall through as if the rule had not matched.
      # `validate_graph/1` surfaces it for the author.
      nil -> fall_through(flow, current)
      target -> {:question, target}
    end
  end

  defp apply_action(flow, current, %SurveyBranch{action: :goto_page} = branch) do
    case questions_on_page(flow, branch.target_page) do
      [] -> fall_through(flow, current)
      [first | _] -> {:question, first}
    end
  end

  defp apply_action(_flow, _current, %SurveyBranch{action: :end_survey}), do: :end

  # Skips the question that would have come next, not the current one.
  defp apply_action(flow, current, %SurveyBranch{action: :skip_question}) do
    at_position(flow, current.position + 2) || :end
  end

  defp fall_through(flow, current) do
    at_position(flow, current.position + 1) || :end
  end

  defp at_position(%__MODULE__{by_position: by_position}, position) do
    case Map.get(by_position, position) do
      nil -> nil
      question -> {:question, question}
    end
  end

  # -- graph validation -----------------------------------------------------

  @doc """
  Checks the survey's logic as a whole and returns the problems found, as
  data for the logic editor to render - never prose, so the UI owns the
  wording and gettext owns the translation.

  These are properties of the whole graph, which is why they live here rather
  than in `SurveyBranch`'s changeset: a rule that is perfectly valid on its
  own can still close a loop with another one.

  Issues, each a map with an `:issue` key:

    * `:all_at_once_with_rules` - the survey shows every question at once, so
      a rule has nowhere to act
    * `:self_target` - a rule jumping to its own question, an immediate loop
    * `:backward_target` - a rule jumping to an earlier question, which lets
      a respondent loop and re-answer
    * `:dangling_target` / `:dangling_page` - a jump to a question or page
      that no longer exists
    * `:forward_clause` - a clause testing an answer the respondent has not
      given yet, so it can never be true
    * `:dangling_clause` - a clause testing a question not in this survey
    * `:matrix_clause_without_row` - a clause on a matrix question that does
      not say which row it means
    * `:clause_without_operand` - a clause whose operator needs a value that
      has not been filled in, so it can never match
    * `:cycle` - a loop through the rules

  An empty list means the logic is sound. Nothing here blocks saving: an
  author mid-edit routinely has a dangling reference, and refusing the save
  would be worse than showing them the list.
  """
  @spec validate_graph(t()) :: [map()]
  def validate_graph(%__MODULE__{} = flow) do
    Enum.concat([
      pagination_issues(flow),
      branch_issues(flow),
      cycle_issues(flow)
    ])
  end

  defp pagination_issues(%__MODULE__{survey: survey} = flow) do
    if (survey.settings && survey.settings.pagination == :all_at_once) and any_rules?(flow) do
      [%{issue: :all_at_once_with_rules}]
    else
      []
    end
  end

  defp any_rules?(%__MODULE__{branches: branches}) do
    Enum.any?(branches, fn {_id, rules} -> rules != [] end)
  end

  defp branch_issues(%__MODULE__{} = flow) do
    Enum.flat_map(flow.questions, fn question ->
      flow.branches
      |> Map.get(question.id, [])
      |> Enum.flat_map(&rule_issues(flow, question, &1))
    end)
  end

  defp rule_issues(flow, question, branch) do
    target_issues(flow, question, branch) ++ clause_issues(flow, question, branch)
  end

  defp target_issues(flow, question, %SurveyBranch{action: :goto_question} = branch) do
    base = %{branch_id: branch.id, question_id: question.id}
    target = question(flow, branch.target_question_id)

    cond do
      branch.target_question_id == question.id ->
        [Map.put(base, :issue, :self_target)]

      is_nil(target) ->
        [
          base
          |> Map.put(:issue, :dangling_target)
          |> Map.put(:target_question_id, branch.target_question_id)
        ]

      target.position <= question.position ->
        [
          base
          |> Map.put(:issue, :backward_target)
          |> Map.put(:target_question_id, target.id)
        ]

      true ->
        []
    end
  end

  defp target_issues(flow, question, %SurveyBranch{action: :goto_page} = branch) do
    case questions_on_page(flow, branch.target_page) do
      [] ->
        [
          %{
            issue: :dangling_page,
            branch_id: branch.id,
            question_id: question.id,
            target_page: branch.target_page
          }
        ]

      [first | _] ->
        if first.position <= question.position do
          [
            %{
              issue: :backward_target,
              branch_id: branch.id,
              question_id: question.id,
              target_question_id: first.id
            }
          ]
        else
          []
        end
    end
  end

  defp target_issues(_flow, _question, %SurveyBranch{}), do: []

  defp clause_issues(_flow, _question, %SurveyBranch{condition: nil}), do: []

  defp clause_issues(flow, question, %SurveyBranch{condition: condition} = branch) do
    Enum.flat_map(condition.clauses || [], fn clause ->
      base = %{
        branch_id: branch.id,
        question_id: question.id,
        clause_question_id: clause.question_id
      }

      case question(flow, clause.question_id) do
        nil ->
          [Map.put(base, :issue, :dangling_clause)]

        tested ->
          cond do
            tested.position > question.position ->
              [Map.put(base, :issue, :forward_clause)]

            tested.type == :multi_scale and not has_row?(clause) ->
              [Map.put(base, :issue, :matrix_clause_without_row)]

            not BranchClause.complete?(clause) ->
              [Map.put(base, :issue, :clause_without_operand)]

            true ->
              []
          end
      end
    end)
  end

  defp has_row?(clause) do
    case Map.get(clause.value || %{}, "row_id") do
      row when is_binary(row) and row != "" -> true
      _ -> false
    end
  end

  # A depth-first search over every edge a respondent could follow - the
  # fall-through edge as well as the jumps - colouring nodes to spot a back
  # edge. Catches loops the per-rule checks cannot see, such as one closed
  # through a page jump.
  defp cycle_issues(%__MODULE__{} = flow) do
    {_colors, issues} =
      Enum.reduce(flow.questions, {%{}, []}, fn question, {colors, issues} ->
        case Map.get(colors, question.id) do
          nil -> dfs(flow, question.id, colors, issues)
          _ -> {colors, issues}
        end
      end)

    Enum.uniq(issues)
  end

  defp dfs(flow, id, colors, issues) do
    colors = Map.put(colors, id, :gray)

    {colors, issues} =
      flow
      |> edge_targets(id)
      |> Enum.reduce({colors, issues}, fn target, {colors, issues} ->
        case Map.get(colors, target) do
          :gray ->
            {colors, [%{issue: :cycle, question_id: id, target_question_id: target} | issues]}

          :black ->
            {colors, issues}

          nil ->
            dfs(flow, target, colors, issues)
        end
      end)

    {Map.put(colors, id, :black), issues}
  end

  defp edge_targets(%__MODULE__{} = flow, question_id) do
    case question(flow, question_id) do
      nil ->
        []

      question ->
        jumps =
          flow.branches
          |> Map.get(question_id, [])
          |> Enum.flat_map(&jump_target(flow, question, &1))

        (jumps ++ List.wrap(successor_id(flow, question.position + 1)))
        |> Enum.uniq()
    end
  end

  defp jump_target(flow, _question, %SurveyBranch{action: :goto_question} = branch) do
    case question(flow, branch.target_question_id) do
      nil -> []
      target -> [target.id]
    end
  end

  defp jump_target(flow, _question, %SurveyBranch{action: :goto_page} = branch) do
    case questions_on_page(flow, branch.target_page) do
      [] -> []
      [first | _] -> [first.id]
    end
  end

  defp jump_target(flow, question, %SurveyBranch{action: :skip_question}) do
    List.wrap(successor_id(flow, question.position + 2))
  end

  defp jump_target(_flow, _question, %SurveyBranch{action: :end_survey}), do: []

  defp successor_id(%__MODULE__{by_position: by_position}, position) do
    case Map.get(by_position, position) do
      nil -> nil
      question -> question.id
    end
  end
end
