defmodule Athena.Surveys.QuestionTypes do
  @moduledoc """
  The registry of survey question types: the `Ecto.Enum` values for
  `Athena.Surveys.SurveyQuestion.type`, the per-type config changeset
  dispatch, and the measurement level each type yields.

  This mirrors `Athena.Content.Block`'s approach to a polymorphic `content`
  column (see `Athena.Content.Block.validate_content_by_type/1`): the column
  is plain jsonb, but every write is validated through a typed embedded
  schema and then round-tripped through JSON, so stored configs are always
  string-keyed and no caller has to care which type it is reading.

  `measurement/1` is what keeps the statistics honest: `Athena.Surveys.Results`
  refuses to compute a mean over a `:nominal` question or a chi-square over a
  `:scale` one, rather than returning a number that looks fine and means
  nothing.
  """

  alias Athena.Surveys.QuestionTypes.{
    Dichotomous,
    Matching,
    MultipleChoice,
    MultiScale,
    Nps,
    Numeric,
    OpenText,
    Ranking,
    Scale,
    SingleChoice
  }

  import Ecto.Changeset

  @all ~w(single_choice multiple_choice dichotomous open_text numeric scale multi_scale matching ranking nps)a

  # Types whose answer is a label, not a quantity: frequencies and crosstabs
  # are meaningful, a mean is not.
  @nominal ~w(single_choice multiple_choice dichotomous matching)a

  # Types whose answer is a number on a fixed set of points: a mean is
  # conventional (and defensible) and so are correlations and reliability.
  @interval ~w(scale multi_scale nps)a

  # Types whose answer is a number on a true ratio scale.
  @ratio ~w(numeric)a

  # Types whose answer is an ordering.
  @ordinal ~w(ranking)a

  # Types whose answer is prose: no aggregation at all, only verbatim listing.
  @text ~w(open_text)a

  # Types that write one answer row per sub-item instead of a single row.
  @multi_row ~w(multi_scale)a

  # Reserved choice ids. They are not UUIDs, so they can never collide with a
  # builder-generated `Option.id`, and they are stable across relabelling: a
  # dichotomous question renamed from "Yes/No" to "Agree/Disagree" keeps every
  # answer already collected.
  @other_choice_id "other"
  @yes_choice_id "yes"
  @no_choice_id "no"

  @type t :: atom()
  @type measurement :: :nominal | :ordinal | :interval | :ratio | :text

  @doc "The reserved choice id recorded for a write-in \"other\" answer."
  @spec other_choice_id() :: String.t()
  def other_choice_id, do: @other_choice_id

  @doc "The reserved choice ids of a `:dichotomous` answer."
  @spec yes_choice_id() :: String.t()
  def yes_choice_id, do: @yes_choice_id

  @spec no_choice_id() :: String.t()
  def no_choice_id, do: @no_choice_id

  @doc "Every question type."
  @spec all() :: [t()]
  def all, do: @all

  @doc """
  The fixed range of an `:nps` question.

  Exposed here rather than from `Nps` itself because the per-type config
  modules are internal to this context - the registry is what the rest of the
  app talks to.
  """
  @spec nps_range() :: Range.t()
  def nps_range, do: Nps.min()..Nps.max()

  @doc """
  The measurement level of a type, which decides what statistics may be run
  over it.
  """
  @spec measurement(t()) :: measurement()
  def measurement(type) when type in @nominal, do: :nominal
  def measurement(type) when type in @ordinal, do: :ordinal
  def measurement(type) when type in @interval, do: :interval
  def measurement(type) when type in @ratio, do: :ratio
  def measurement(type) when type in @text, do: :text

  @doc """
  Whether a question of this type writes one answer row per sub-item (a
  matrix row) rather than a single answer row - in which case `row_key` on
  `Athena.Surveys.SurveyAnswer` is populated.
  """
  @spec multi_row?(t()) :: boolean()
  def multi_row?(type), do: type in @multi_row

  @doc "Whether a mean, SD and correlation are defined for this type."
  @spec quantitative?(t()) :: boolean()
  def quantitative?(type), do: measurement(type) in [:interval, :ratio]

  @doc """
  Builds the validating changeset for a question's `config` map, dispatching
  on the question type. Every type has a config schema, so unlike
  `Athena.Content.Block` there is no "no embed for this type" case.
  """
  @spec config_changeset(t(), map()) :: Ecto.Changeset.t()
  def config_changeset(:single_choice, attrs), do: SingleChoice.changeset(%SingleChoice{}, attrs)

  def config_changeset(:multiple_choice, attrs),
    do: MultipleChoice.changeset(%MultipleChoice{}, attrs)

  def config_changeset(:dichotomous, attrs), do: Dichotomous.changeset(%Dichotomous{}, attrs)
  def config_changeset(:open_text, attrs), do: OpenText.changeset(%OpenText{}, attrs)
  def config_changeset(:numeric, attrs), do: Numeric.changeset(%Numeric{}, attrs)
  def config_changeset(:scale, attrs), do: Scale.changeset(%Scale{}, attrs)
  def config_changeset(:multi_scale, attrs), do: MultiScale.changeset(%MultiScale{}, attrs)
  def config_changeset(:matching, attrs), do: Matching.changeset(%Matching{}, attrs)
  def config_changeset(:ranking, attrs), do: Ranking.changeset(%Ranking{}, attrs)
  def config_changeset(:nps, attrs), do: Nps.changeset(%Nps{}, attrs)

  @doc """
  The config a freshly added question of this type starts with in the builder
  - enough to be a valid, answerable question the moment it is created, so a
  new card never renders as an error.
  """
  @spec default_config(t()) :: map()
  def default_config(type) when type in [:single_choice, :multiple_choice] do
    %{
      "options" => [new_option(1), new_option(2)],
      "other_allowed" => false,
      "randomize" => false
    }
  end

  def default_config(:dichotomous), do: %{"yes_label" => "Yes", "no_label" => "No"}
  def default_config(:open_text), do: %{"multiline" => true, "max_length" => 2000}
  def default_config(:numeric), do: %{"step" => 1.0}
  def default_config(:scale), do: %{"min" => 1, "max" => 5, "step" => 1}

  def default_config(:multi_scale),
    do: %{"rows" => [new_row(1)], "min" => 1, "max" => 5, "step" => 1}

  def default_config(:matching), do: %{"pairs" => [new_pair(1), new_pair(2)]}
  def default_config(:ranking), do: %{"items" => [new_option(1), new_option(2)]}
  def default_config(:nps), do: %{}

  @doc """
  Shared "needs at least N options" validation for the choice-shaped configs.
  A one-option choice question is not a question.
  """
  @spec validate_min_options(Ecto.Changeset.t(), pos_integer()) :: Ecto.Changeset.t()
  def validate_min_options(changeset, minimum) do
    if length(get_field(changeset, :options) || []) < minimum do
      add_error(changeset, :options, "must have at least #{minimum} options")
    else
      changeset
    end
  end

  # Placeholder labels, not blanks: a question's config is validated on every
  # save, and `Option.text` is required - so a card created with empty labels
  # would be born invalid and the builder could not save the question the user
  # is still typing into.
  defp new_option(n), do: %{"id" => Ecto.UUID.generate(), "text" => "Option #{n}"}

  defp new_row(n), do: %{"id" => Ecto.UUID.generate(), "text" => "Item #{n}"}

  defp new_pair(n),
    do: %{"id" => Ecto.UUID.generate(), "left" => "Left #{n}", "right" => "Right #{n}"}
end
