defmodule Athena.Announcements.Announcement do
  @moduledoc """
  An admin/instructor-authored announcement, visible either to everyone
  (`:global`) or to the members of selected cohorts (`:cohort`).

  `body` stores a TipTap/ProseMirror JSON document (jsonb), not plain
  text – rendered client-side by the same `TiptapEditor` hook used for
  course content. Visibility can optionally be windowed via `starts_at`/
  `ends_at`: when both are `nil` the announcement is visible immediately
  and indefinitely; when set, `Athena.Announcements.list_for_viewer/2`
  only returns it while `starts_at <= now <= ends_at` (either bound may be
  set alone).

  References `cohort_id` and `author_id` as bare ids with no foreign-key
  constraint and no `belongs_to` – this schema belongs strictly to the
  Announcements context and maintains loose coupling to Learning/Identity,
  the same convention `Athena.Media.File.owner_id` establishes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.Tiptap

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
    field :cohort_ids, {:array, :binary_id}, default: []
    field :author_id, :binary_id
    field :important, :boolean, default: false
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(announcement, attrs) do
    attrs = normalize_audience(attrs)

    announcement
    |> cast(attrs, [
      :title,
      :body,
      :scope,
      :cohort_id,
      :cohort_ids,
      :author_id,
      :important,
      :starts_at,
      :ends_at
    ])
    |> update_change(:body, &Tiptap.strip_colors/1)
    |> validate_required([:title, :body, :scope, :author_id])
    |> validate_length(:title, max: 200)
    |> validate_cohort_id_for_scope()
    |> validate_visibility_window()
  end

  defp validate_cohort_id_for_scope(changeset) do
    case get_field(changeset, :scope) do
      :cohort ->
        changeset = update_change(changeset, :cohort_ids, &Enum.uniq/1)
        ids = get_field(changeset, :cohort_ids) || []
        changeset = put_change(changeset, :cohort_id, List.first(ids))

        if ids == [], do: add_error(changeset, :cohort_ids, "can't be blank"), else: changeset

      :global ->
        changeset |> put_change(:cohort_id, nil) |> put_change(:cohort_ids, [])

      _ ->
        changeset
    end
  end

  # Accept the former single-recipient API while storing the full audience.
  def normalize_audience(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    cond do
      Map.has_key?(attrs, "cohort_ids") ->
        Map.update!(attrs, "cohort_ids", &normalize_cohort_ids/1)

      Map.has_key?(attrs, "cohort_id") ->
        Map.put(attrs, "cohort_ids", List.wrap(attrs["cohort_id"]))

      true ->
        attrs
    end
  end

  defp normalize_cohort_ids(ids) when is_list(ids),
    do: Enum.reject(ids, &(&1 in [nil, ""]))

  defp normalize_cohort_ids(ids), do: ids

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
