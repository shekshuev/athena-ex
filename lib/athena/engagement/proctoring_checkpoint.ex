defmodule Athena.Engagement.ProctoringCheckpoint do
  @moduledoc """
  Durable checkpoint of an in-progress exam attempt's
  `Athena.Engagement.ProctoringMonitor` state, so the monitor can resume
  its accumulated integrity signals after a node restart or a monitor
  crash instead of starting from zero (its counters otherwise live only in
  memory until `finalize/1`).

  The state is stored as an opaque `:erlang.term_to_binary/1` blob keyed by
  submission id. Every operation here is **best-effort and never raises**:
  persistence must never take down the live exam path, and a checkpoint
  that can't be read (corrupt, or from an incompatible monitor version) is
  treated as "no checkpoint" so the monitor simply starts fresh.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Athena.Repo

  @primary_key {:submission_id, :binary_id, autogenerate: false}
  schema "exam_proctoring_checkpoints" do
    field :data, :binary

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Upserts the serializable monitor state for one attempt. Returns `:ok`
  whatever happens - a failed write just means the next tick will try again.
  """
  @spec save(binary(), term()) :: :ok
  def save(submission_id, state_term) do
    now = DateTime.utc_now()
    # `:compressed` keeps the blob small - the incident and away-interval
    # lists compress well, so a typical checkpoint is a couple of KB.
    data = :erlang.term_to_binary(state_term, [:compressed])

    Repo.insert_all(
      __MODULE__,
      [%{submission_id: submission_id, data: data, inserted_at: now, updated_at: now}],
      on_conflict: {:replace, [:data, :updated_at]},
      conflict_target: :submission_id
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Loads a previously saved state term, or `nil` if there is none or it
  can't be deserialized. Uses `binary_to_term/2` with `:safe` (no new atoms
  are created from the stored blob). Never raises.
  """
  @spec load(binary()) :: term() | nil
  def load(submission_id) do
    case Repo.get(__MODULE__, submission_id) do
      %__MODULE__{data: data} when is_binary(data) ->
        try do
          :erlang.binary_to_term(data, [:safe])
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "Removes the checkpoint for one attempt (called when it is finalized). Never raises."
  @spec delete(binary()) :: :ok
  def delete(submission_id) do
    from(c in __MODULE__, where: c.submission_id == ^submission_id)
    |> Repo.delete_all()

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Deletes checkpoints not updated within `older_than_seconds` (default 24h) -
  orphans of attempts that were abandoned (a closed tab, a crash) and so
  never reached `finalize/1` to clean up after themselves. A live attempt
  rewrites its checkpoint about once a minute, so a row untouched for this
  long belongs to an attempt that is long over. Returns the number of rows
  removed; never raises.
  """
  @spec purge_stale(non_neg_integer()) :: non_neg_integer()
  def purge_stale(older_than_seconds \\ 86_400) do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_seconds, :second)

    {deleted, _} =
      from(c in __MODULE__, where: c.updated_at < ^cutoff)
      |> Repo.delete_all()

    deleted
  rescue
    _ -> 0
  end
end
