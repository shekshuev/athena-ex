defmodule Athena.Surveys.Survey do
  @moduledoc """
  A self-contained questionnaire used to collect feedback from students.

  A survey is **not** a library block. Unlike `:quiz_exam`/`:ticket_exam`,
  which assemble themselves from a pool of `Athena.Content.LibraryBlock`
  questions, a survey is authored once as a whole and referenced from a
  course by a `:survey` block (`Athena.Content.SurveyRef`). That reference is
  the only way students reach it. It is not graded and earns no XP.

  `description` stores a TipTap/ProseMirror JSON document (jsonb), the same as
  `Athena.Announcements.Announcement.body`.

  `owner_id` is a bare id with no foreign key and no `belongs_to`, the
  convention this codebase uses for cross-context references (see that
  moduledoc). The column *must* be named `owner_id`: `Athena.Identity.Acl`'s
  `own_only` policy and `scope_query/3` resolve ownership by that exact field.

  ## Lifecycle

  `:draft` -> `:published` -> `:closed` -> `:archived`. Questions may be
  edited freely while no response exists; once one does, editing them would
  silently change what the collected answers mean, so
  `Athena.Surveys.Surveys.editable?/1` locks them and the builder offers
  "duplicate as new version" instead - a new survey row carrying
  `source_survey_id`. That is the whole versioning story; there are no
  per-question versions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Surveys.{SurveyQuestion, SurveySettings}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:title, :status, :owner_id],
    sortable: [:title, :status, :inserted_at],
    default_limit: 20,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "surveys" do
    field :title, :string
    field :description, :map
    field :status, Ecto.Enum, values: [:draft, :published, :closed, :archived], default: :draft
    field :owner_id, :binary_id
    field :source_survey_id, :binary_id
    field :published_at, :utc_datetime
    field :closed_at, :utc_datetime

    embeds_one :settings, SurveySettings, on_replace: :update

    has_many :questions, SurveyQuestion, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(survey, attrs) do
    survey
    |> cast(attrs, [:title, :description, :status, :owner_id, :source_survey_id])
    |> cast_embed(:settings, with: &SurveySettings.changeset/2)
    |> validate_required([:title, :owner_id, :status])
    |> validate_length(:title, max: 200)
    |> ensure_settings()
  end

  # Every read path (the player, the builder, the flow engine) consults
  # `settings`, so it is never left nil - a survey created with no settings at
  # all gets the defaults rather than forcing every caller to handle `nil`.
  defp ensure_settings(changeset) do
    case get_field(changeset, :settings) do
      nil -> put_change(changeset, :settings, %SurveySettings{})
      _ -> changeset
    end
  end
end
