defmodule Athena.Engagement.Purges do
  @moduledoc """
  Deleting a student's or a cohort's raw engagement events while keeping
  everything computed from them.

  Raw events are otherwise kept forever. A purge removes the rows of one
  account (or one cohort) recorded up to the moment it was requested, but
  the daily rollups (`Athena.Engagement.Rollups`) - what every dashboard
  reads - stay as they are:

    * the deletion (`Athena.Engagement.Workers.PurgeRawEvents`) waits until
      the rollup worker has folded in every event being deleted;
    * once the deletion starts, the rollup worker no longer recomputes that
      account's (or cohort's) days up to the purge day: a recompute would
      rebuild them from raw events that are no longer there. Events
      recorded for them later on the purge day itself are therefore not
      added to that day's aggregates. The switch happens under the same
      advisory lock every rollup batch holds, so no batch can be halfway
      through a recompute when the deletion begins;
    * `Rollups.reset/0` refuses to run once anything was purged.

  What is lost are the views that read raw events: the live block view for
  past days of those students is still served from rollups, but their exam
  proctoring timelines are gone.
  """

  import Ecto.Query
  require Logger

  alias Athena.{Identity, Repo, TimeZones}
  alias Athena.Engagement.{Event, Purge, Rollups}
  alias Athena.Engagement.Workers.PurgeRawEvents

  @batch_size 10_000
  @tables ["engagement_events", "engagement_events_legacy"]

  @doc """
  Schedules the deletion of the raw events of an account (`:account`) or a
  cohort (`:cohort`), recorded up to now. Requires `engagement.delete`.
  """
  @spec request(map(), :account | :cohort, binary()) ::
          {:ok, Purge.t()} | {:error, :forbidden | term()}
  def request(user, scope, scope_id) when scope in [:account, :cohort] do
    if Identity.can?(user, "engagement.delete") do
      purge = %Purge{
        scope: scope,
        scope_id: scope_id,
        purged_through: DateTime.utc_now(:second),
        requested_by: user.id
      }

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:purge, purge)
      |> Oban.insert(:job, fn %{purge: purge} -> PurgeRawEvents.new(%{purge_id: purge.id}) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{purge: purge}} -> {:ok, purge}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Carries out a purge once its events are folded into the rollups:
  `{:snooze, seconds}` while they aren't yet, `:ok` once done.
  """
  @spec run(Purge.t()) :: :ok | {:snooze, pos_integer()}
  def run(%Purge{status: :done}), do: :ok

  def run(%Purge{} = purge) do
    if folded?(purge) do
      start_deleting(purge)
      deleted = Enum.sum(for table <- @tables, do: delete_from(table, purge))

      purge
      |> Ecto.Changeset.change(
        status: :done,
        deleted_count: deleted,
        completed_at: DateTime.utc_now(:second)
      )
      |> Repo.update!()

      Logger.info(
        "[Engagement.Purges] deleted #{deleted} raw events of #{purge.scope} #{purge.scope_id}"
      )

      :ok
    else
      {:snooze, 300}
    end
  end

  # From here on the rollup worker leaves this scope's days alone; taking
  # the rollup lock first waits out any batch already recomputing them.
  defp start_deleting(%Purge{status: :deleting}), do: :ok

  defp start_deleting(purge) do
    Repo.transaction(fn ->
      Rollups.lock()
      purge |> Ecto.Changeset.change(status: :deleting) |> Repo.update!()
    end)
  end

  @doc """
  The last protected day per purged account and cohort among the given
  ones: `%{{:account | :cohort, id} => Date.t()}` (app timezone). The
  rollup worker never recomputes a purged account's or cohort's day on or
  before it.
  """
  @spec protected_days([binary()], [binary()]) :: %{{atom(), binary()} => Date.t()}
  def protected_days(cohort_ids, account_ids) do
    from(p in Purge,
      where: p.status in [:deleting, :done],
      where:
        (p.scope == :cohort and p.scope_id in ^cohort_ids) or
          (p.scope == :account and p.scope_id in ^account_ids),
      group_by: [p.scope, p.scope_id],
      select: {p.scope, p.scope_id, max(p.purged_through)}
    )
    |> Repo.all()
    |> Map.new(fn {scope, id, through} ->
      {{scope, id}, through |> TimeZones.to_app_zone() |> DateTime.to_date()}
    end)
  end

  @doc "Whether any raw events were ever purged."
  @spec any?() :: boolean()
  def any?, do: Repo.exists?(Purge)

  # Every event being deleted is already behind the rollup cursor.
  defp folded?(purge) do
    cursor = Rollups.cursor()

    not Repo.exists?(
      Event
      |> where([e], field(e, ^scope_field(purge)) == ^purge.scope_id)
      |> where([e], e.inserted_at <= ^purge.purged_through)
      |> then(fn q -> if cursor, do: where(q, [e], e.inserted_at > ^cursor), else: q end)
    )
  end

  # Batches by primary key, so neither a big cohort nor the partitioned
  # table's size holds one long transaction or lock.
  defp delete_from(table, purge) do
    if table_exists?(table) do
      delete_batches(table, purge, 0)
    else
      0
    end
  end

  defp delete_batches(table, purge, total) do
    field = Atom.to_string(scope_field(purge))

    %{num_rows: deleted} =
      Repo.query!(
        """
        DELETE FROM #{table} WHERE (id, inserted_at) IN (
          SELECT id, inserted_at FROM #{table}
          WHERE #{field} = $1 AND inserted_at <= $2
          LIMIT $3
        )
        """,
        [
          Ecto.UUID.dump!(purge.scope_id),
          DateTime.to_naive(purge.purged_through),
          @batch_size
        ],
        timeout: :timer.minutes(2)
      )

    if deleted < @batch_size,
      do: total + deleted,
      else: delete_batches(table, purge, total + deleted)
  end

  defp scope_field(%Purge{scope: :account}), do: :account_id
  defp scope_field(%Purge{scope: :cohort}), do: :cohort_id

  defp table_exists?(table) do
    %{rows: [[oid]]} = Repo.query!("SELECT to_regclass($1)::oid", [table])
    not is_nil(oid)
  end
end
