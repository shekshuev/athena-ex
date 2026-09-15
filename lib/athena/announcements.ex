defmodule Athena.Announcements do
  @moduledoc """
  Business logic for admin/instructor-authored announcements.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Announcements.Announcement
  alias Athena.{Identity, Learning}

  @doc """
  Audience-scoped, Flop-paginated feed for `user`: global announcements
  plus announcements for any cohort `user` is a *member* of, further
  restricted to those currently within their visibility window (see
  `Announcement` moduledoc — `starts_at`/`ends_at`, either or both may be
  `nil`). Used for both the dashboard widget (call with `%{"page_size" =>
  5}`) and the full `/announcements` page — a single paginated function
  rather than a separate unpaginated "latest N" helper, since "latest 5"
  is just "page 1, page_size 5" of the same already-ordered
  (`default_order: inserted_at desc`) query.
  """
  @spec list_for_viewer(map(), map()) ::
          {:ok, {[Announcement.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_viewer(user, params \\ %{}) do
    member_cohort_ids = Learning.list_member_cohort_ids(user.id)
    now = DateTime.utc_now()

    Announcement
    |> where([a], a.scope == :global or a.cohort_id in ^member_cohort_ids)
    |> where([a], is_nil(a.starts_at) or a.starts_at <= ^now)
    |> where([a], is_nil(a.ends_at) or a.ends_at >= ^now)
    |> Flop.validate_and_run(params, for: Announcement)
  end

  @doc """
  Flop-paginated feed for `AdminLive.Announcements`: an "admin"-bypass
  account sees every announcement; a non-admin account holding
  `announcements.read` sees global announcements plus cohort
  announcements for cohorts they instruct; anyone else sees nothing.
  """
  @spec list_for_admin(map(), map()) ::
          {:ok, {[Announcement.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_for_admin(user, params \\ %{}) do
    Announcement
    |> scope_admin_query(user)
    |> Flop.validate_and_run(params, for: Announcement)
  end

  defp scope_admin_query(query, user) do
    cond do
      Identity.can?(user, "admin") ->
        query

      Identity.can?(user, "announcements.read") ->
        instructed_ids = Learning.list_instructed_cohort_ids(user.id)

        where(
          query,
          [a],
          a.scope == :global or (a.scope == :cohort and a.cohort_id in ^instructed_ids)
        )

      true ->
        where(query, [a], false)
    end
  end

  @doc "Gets a single announcement by id, unscoped by ACL. `nil` if not found."
  @spec get_announcement(String.t()) :: Announcement.t() | nil
  def get_announcement(id), do: Repo.get(Announcement, id)

  @doc "Same as `get_announcement/1` but raises if not found."
  @spec get_announcement!(String.t()) :: Announcement.t()
  def get_announcement!(id), do: Repo.get!(Announcement, id)

  @doc """
  Can `user` create/edit/delete an announcement with this `scope`/`cohort_id`?
  A `:global` announcement requires the "admin" bypass. A `:cohort`
  announcement requires the "admin" bypass OR being a listed instructor of
  `cohort_id` — mirrors the `authorized?` boolean pattern in
  `Content.Blocks.prepare_media_upload/4`.
  """
  @spec can_manage?(map(), :global | :cohort, String.t() | nil) :: boolean()
  def can_manage?(user, :global, _cohort_id), do: Identity.can?(user, "admin")

  def can_manage?(user, :cohort, cohort_id) do
    Identity.can?(user, "admin") or
      (not is_nil(cohort_id) and Learning.instructor_of_cohort?(user.id, cohort_id))
  end

  def can_manage?(_user, _scope, _cohort_id), do: false

  @doc "Can `user` manage this already-persisted announcement (edit/delete)?"
  @spec can_manage?(map(), Announcement.t()) :: boolean()
  def can_manage?(user, %Announcement{scope: scope, cohort_id: cohort_id}),
    do: can_manage?(user, scope, cohort_id)

  @doc """
  Creates an announcement authored by `user`. Enforces `announcements.create`
  plus the scope-specific check in `can_manage?/3`:
    - `scope: "global"` → requires the "admin" bypass (a role could hold
      `announcements.create` without "admin"; such a role can never post
      globally).
    - `scope: "cohort"` → requires `announcements.create` AND
      (admin OR instructor of the given `cohort_id`).
  Returns `{:error, :forbidden}` if the check fails, before touching the
  changeset, so a rejected request never leaks validation errors about a
  cohort the user has no business posting to.
  """
  @spec create_announcement(map(), map()) ::
          {:ok, Announcement.t()} | {:error, Ecto.Changeset.t()} | {:error, :forbidden}
  def create_announcement(user, attrs) do
    scope = normalize_scope(attrs)
    cohort_id = attrs["cohort_id"] || attrs[:cohort_id]

    if Identity.can?(user, "announcements.create") and can_manage?(user, scope, cohort_id) do
      %Announcement{}
      |> Announcement.changeset(attrs |> decode_body() |> Map.put("author_id", user.id))
      |> Repo.insert()
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Updates `announcement`. Authorization is checked against BOTH the
  announcement's current scope/cohort_id and, if `attrs` changes them, the
  prospective new scope/cohort_id — this prevents a cohort instructor from
  re-scoping their own cohort's announcement to `:global`, or to a cohort
  they don't instruct, by simply editing the scope/cohort fields.
  """
  @spec update_announcement(map(), Announcement.t(), map()) ::
          {:ok, Announcement.t()} | {:error, Ecto.Changeset.t()} | {:error, :forbidden}
  def update_announcement(user, %Announcement{} = announcement, attrs) do
    new_scope = normalize_scope(attrs) || announcement.scope

    new_cohort_id =
      attrs["cohort_id"] || attrs[:cohort_id] ||
        (new_scope == announcement.scope && announcement.cohort_id)

    authorized? =
      Identity.can?(user, "announcements.update") and
        can_manage?(user, announcement) and
        can_manage?(user, new_scope, new_cohort_id)

    if authorized? do
      announcement
      |> Announcement.changeset(decode_body(attrs))
      |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  @doc "Deletes `announcement` if `user` holds `announcements.delete` and can manage it."
  @spec delete_announcement(map(), Announcement.t()) ::
          {:ok, Announcement.t()} | {:error, Ecto.Changeset.t()} | {:error, :forbidden}
  def delete_announcement(user, %Announcement{} = announcement) do
    if Identity.can?(user, "announcements.delete") and can_manage?(user, announcement) do
      Repo.delete(announcement)
    else
      {:error, :forbidden}
    end
  end

  # The TipTap editor hook posts its JSON document through a hidden form
  # field as a *string* (`JSON.stringify(editor.getJSON())`), since HTML
  # form fields are always strings client-side — decode it back into a
  # map before it reaches the `:map`-typed `body` column/changeset field.
  defp decode_body(%{"body" => body} = attrs) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> Map.put(attrs, "body", decoded)
      {:error, _} -> attrs
    end
  end

  defp decode_body(attrs), do: attrs

  @doc """
  Extracts plain text from a TipTap/ProseMirror JSON document, for
  previews (e.g. the dashboard widget) that don't warrant mounting a full
  read-only editor instance.
  """
  @spec preview_text(map()) :: String.t()
  def preview_text(body) when is_map(body) do
    body |> extract_text() |> String.trim()
  end

  def preview_text(_), do: ""

  defp extract_text(%{"text" => text}) when is_binary(text), do: text

  defp extract_text(%{"content" => children}) when is_list(children) do
    Enum.map_join(children, " ", &extract_text/1)
  end

  defp extract_text(_), do: ""

  defp normalize_scope(attrs) do
    case attrs["scope"] || attrs[:scope] do
      "global" -> :global
      "cohort" -> :cohort
      atom when atom in [:global, :cohort] -> atom
      _ -> nil
    end
  end
end
