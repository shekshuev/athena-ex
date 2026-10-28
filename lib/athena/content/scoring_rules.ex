defmodule Athena.Content.ScoringRules do
  @moduledoc """
  How a competition ranks its teams: what a solved task is worth, and how
  ties are broken.

  `nil` scoring - every course that has never been configured - resolves
  to the defaults here, and the defaults are exactly what the leaderboard
  did before this existed: a block is worth the submission's 0-100 score,
  and equal totals are settled by who got there first, then by who needed
  fewer attempts.

  Two modes:

    * `:static` - a block is worth `points` (the block's own weight, or
      100), scaled by the team's score on it. Everyone who solves a task
      gets the same for it.

    * `:dynamic` - CTF-style decay: a task is worth less the more teams
      solve it, so finding what others could not is worth more than
      clearing what everyone cleared. See `block_value/3`.

  Deliberately scoped to team ranking. Personal XP, badges and combos read
  the raw submission score (`Athena.Gamification`), and a block's value
  must not leak into them: a task getting cheaper because rivals solved it
  says nothing about what the student who solved it learned.
  """
  use Ecto.Schema
  import Ecto.Changeset
  use Gettext, backend: AthenaWeb.Gettext

  @type t :: %__MODULE__{}

  @default_block_points 100

  @primary_key false
  embedded_schema do
    field :mode, Ecto.Enum, values: [:static, :dynamic], default: :static

    # Dynamic mode only. Kept even while `:static` is selected so toggling
    # the mode back does not throw the author's numbers away.
    field :initial, :integer, default: 500
    field :minimum, :integer, default: 100
    field :decay, :integer, default: 20
    field :curve, Ecto.Enum, values: [:linear, :logarithmic], default: :linear
    field :solve_threshold, :integer, default: 100

    field :tiebreakers, {:array, Ecto.Enum},
      values: [:time, :attempts, :first_blood],
      default: [:time, :attempts]

    field :disqualify_on_rejected, :boolean, default: true
  end

  @doc """
  The rules to score by, with `nil` meaning "the defaults".

  Every consumer goes through this, so an unconfigured competition is
  handled in exactly one place.
  """
  @spec resolve(t() | nil) :: t()
  def resolve(nil), do: %__MODULE__{}
  def resolve(%__MODULE__{mode: nil}), do: %__MODULE__{}
  def resolve(%__MODULE__{} = rules), do: rules

  @doc """
  What a block is currently worth, given how many teams have solved it.

  In `:static` mode that is simply the block's weight. In `:dynamic` mode
  it decays from the block's weight (or `initial`, for an unweighted
  block) down to `minimum`:

      effective = max(solves - 1, 0)
      linear:       base - decay * effective
      logarithmic:  ceil(((minimum - base) / decay^2) * effective^2 + base)

  The `solves - 1` is CTFd's own adjustment and the part worth knowing:
  the first team to solve a task always gets its full value, and decay
  only starts with the second.
  """
  @spec block_value(t(), integer() | nil, non_neg_integer()) :: integer()
  def block_value(%__MODULE__{mode: :static}, block_points, _solves),
    do: base_value(block_points, @default_block_points)

  def block_value(%__MODULE__{} = rules, block_points, solves) do
    base = base_value(block_points, rules.initial)
    effective = max(solves - 1, 0)

    value =
      case rules.curve do
        :linear ->
          base - rules.decay * effective

        :logarithmic ->
          ceil(
            (rules.minimum - base) / (rules.decay * rules.decay) * (effective * effective) + base
          )
      end

    value |> min(base) |> max(rules.minimum)
  end

  @doc """
  A team's points for one block: its share of what the block is worth.

  A partial score earns a partial share, so 60/100 on a block worth 300 is
  180.
  """
  @spec points(t(), integer() | nil, non_neg_integer(), integer() | nil) :: integer()
  def points(%__MODULE__{} = rules, block_points, solves, score) do
    value = block_value(rules, block_points, solves)

    round(value * clamp_score(score) / 100)
  end

  @doc """
  Whether a team's best attempt at a block counts as a solve for decay.

  Only a solve makes a task cheaper for everyone else, so the bar is the
  configured threshold - 100 by default, meaning only complete work
  decays a task, and an essay still awaiting a grade (no score at all)
  decays nothing.
  """
  @spec solve?(t(), integer() | nil) :: boolean()
  def solve?(%__MODULE__{} = rules, score), do: clamp_score(score) >= rules.solve_threshold

  @doc false
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :mode,
      :initial,
      :minimum,
      :decay,
      :curve,
      :solve_threshold,
      :tiebreakers,
      :disqualify_on_rejected
    ])
    |> validate_required([:mode])
    |> normalize_tiebreakers()
    |> validate_dynamic_params()
  end

  defp normalize_tiebreakers(changeset) do
    case get_field(changeset, :tiebreakers) do
      list when list in [nil, []] ->
        put_change(changeset, :tiebreakers, [:time, :attempts])

      list ->
        if length(Enum.uniq(list)) == length(list) do
          changeset
        else
          add_error(
            changeset,
            :tiebreakers,
            dgettext_noop("errors", "must not repeat the same tiebreaker")
          )
        end
    end
  end

  defp validate_dynamic_params(changeset) do
    if get_field(changeset, :mode) == :dynamic do
      changeset
      |> validate_number(:initial, greater_than: 0)
      |> validate_number(:minimum, greater_than: 0)
      # A zero decay divides by zero on the logarithmic curve.
      |> validate_number(:decay, greater_than: 0)
      |> validate_number(:solve_threshold,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 100
      )
      |> validate_minimum_within_initial()
    else
      changeset
    end
  end

  defp validate_minimum_within_initial(changeset) do
    initial = get_field(changeset, :initial)
    minimum = get_field(changeset, :minimum)

    if is_integer(initial) and is_integer(minimum) and minimum > initial do
      add_error(
        changeset,
        :minimum,
        dgettext_noop("errors", "can't be higher than the initial value")
      )
    else
      changeset
    end
  end

  defp base_value(points, _fallback) when is_integer(points) and points > 0, do: points
  defp base_value(_points, fallback), do: fallback

  defp clamp_score(score) when is_integer(score), do: score |> max(0) |> min(100)
  defp clamp_score(_score), do: 0
end
