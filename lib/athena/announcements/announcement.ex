defmodule Athena.Announcements.Announcement do
  @moduledoc """
  An admin/instructor-authored announcement, visible either to everyone
  (`:global`) or to the members of one specific cohort (`:cohort`).

  `body` stores a TipTap/ProseMirror JSON document (jsonb), not plain
  text — rendered client-side by the same `TiptapEditor` hook used for
  course content. Visibility can optionally be windowed via `starts_at`/
  `ends_at`: when both are `nil` the announcement is visible immediately
  and indefinitely; when set, `Athena.Announcements.list_for_viewer/2`
  only returns it while `starts_at <= now <= ends_at` (either bound may be
  set alone).

  References `cohort_id` and `author_id` as bare ids with no foreign-key
  constraint and no `belongs_to` — this schema belongs strictly to the
  Announcements context and maintains loose coupling to Learning/Identity,
  the same convention `Athena.Media.File.owner_id` establishes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:title, :scope, :important],
    sortable: [:title, :inserted_at],
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "announcements" do
    field :title, :string
    field :body, :map
    field :scope, Ecto.Enum, values: [:global, :cohort]
    field :cohort_id, :binary_id
    field :author_id, :binary_id
    field :important, :boolean, default: false
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(announcement, attrs) do
    announcement
    |> cast(attrs, [
      :title,
      :body,
      :scope,
      :cohort_id,
      :author_id,
      :important,
      :starts_at,
      :ends_at
    ])
    |> validate_required([:title, :body, :scope, :author_id])
    |> validate_length(:title, max: 200)
    |> validate_cohort_id_for_scope()
    |> validate_visibility_window()
  end

  defp validate_cohort_id_for_scope(changeset) do
    case get_field(changeset, :scope) do
      :cohort -> validate_required(changeset, [:cohort_id])
      :global -> put_change(changeset, :cohort_id, nil)
      _ -> changeset
    end
  end

  defp validate_visibility_window(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(starts_at, ends_at) != :lt do
      add_error(changeset, :ends_at, "must be after the start date")
    else
      changeset
    end
  end
end
