defmodule Athena.Content.SearchIndexConcurrencyTest do
  use ExUnit.Case, async: false

  import Athena.Factory
  import Ecto.Query

  alias Athena.Content.{Block, Blocks, SearchIndex}
  alias Athena.Content.Workers.IndexBlockSearch
  alias Athena.Repo
  alias Ecto.Adapters.SQL.Sandbox

  # These tests deliberately commit fixture data. Each task checks out its
  # own unsandboxed connection, so PostgreSQL really arbitrates row locks.
  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    role = insert(:role, permissions: ["admin", "courses.update"])
    admin = insert(:account, role: role)
    course = insert(:course, owner_id: admin.id)
    section = insert(:section, course: course)
    block = insert(:block, section: section, content: doc("Before"), search_due_at: past())

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from j in Oban.Job, where: fragment("? ->> 'block_id'", j.args) == ^block.id
        )

        Repo.delete!(course)
        Repo.delete!(admin)
        Repo.delete!(role)
      end)
    end)

    %{admin: admin, block: block}
  end

  test "an edit waiting for the extractor lock keeps its own follow-up task", ctx do
    {worker, worker_backend} = connection_task(fn -> perform(ctx.block) end)
    pause_worker_after_lock(worker)
    send(worker, :run)
    assert_receive {:row_locked, ^worker}

    {editor, editor_backend} =
      connection_task(fn ->
        Blocks.update_block(ctx.admin, ctx.block, %{"content" => doc("After")})
      end)

    send(editor, :run)
    await_blocked(editor_backend, worker_backend)
    send(worker, :release)

    assert_receive {:finished, ^worker, :ok}
    assert_receive {:finished, ^editor, {:ok, edited}}
    block = Repo.get!(Block, ctx.block.id)
    assert block.search_text == "Before"
    assert block.content == doc("After")
    assert block.search_due_at == edited.search_due_at
    assert scheduled_job?(block)

    mark_overdue(block)
    assert :ok = perform(block)
    assert %{search_text: "After", search_due_at: nil} = Repo.get!(Block, block.id)
  end

  test "a worker waiting for an edit reads the committed deadline and snoozes", ctx do
    parent = self()

    {editor, editor_backend} =
      connection_task(fn ->
        Repo.transaction(fn ->
          {:ok, edited} = Blocks.update_block(ctx.admin, ctx.block, %{"content" => doc("After")})
          send(parent, {:edit_held, self()})

          receive do
            :release -> edited
          end
        end)
      end)

    send(editor, :run)
    assert_receive {:edit_held, ^editor}
    {worker, worker_backend} = connection_task(fn -> perform(ctx.block) end)
    send(worker, :run)
    await_blocked(worker_backend, editor_backend)
    send(editor, :release)

    assert_receive {:finished, ^editor, {:ok, _edited}}
    assert_receive {:finished, ^worker, {:snooze, delay}}
    assert delay in 1..60
    block = Repo.get!(Block, ctx.block.id)
    assert is_nil(block.search_text)
    assert block.search_due_at
    assert scheduled_job?(block)
  end

  test "two worker connections serialize and the second sees the completed index", ctx do
    {first, first_backend} = connection_task(fn -> perform(ctx.block) end)
    pause_worker_after_lock(first)
    send(first, :run)
    assert_receive {:row_locked, ^first}

    {second, second_backend} = connection_task(fn -> perform(ctx.block) end)
    send(second, :run)
    await_blocked(second_backend, first_backend)
    send(first, :release)

    assert_receive {:finished, ^first, :ok}
    assert_receive {:finished, ^second, :ok}
    assert %{search_text: "Before", search_due_at: nil} = Repo.get!(Block, ctx.block.id)
    assert Repo.get!(Block, ctx.block.id).updated_at == ctx.block.updated_at
  end

  test "Oban can report a unique conflict without a persisted job", ctx do
    parent = self()
    config = %{Oban.config() | testing: :disabled}

    {enqueuer, _backend} =
      connection_task(fn ->
        Repo.transaction(fn ->
          changeset = IndexBlockSearch.new(%{block_id: ctx.block.id}, schedule_in: 60)
          {:ok, %Oban.Job{id: id}} = Oban.Engines.Basic.insert_job(config, changeset, [])

          assert is_integer(id)
          send(parent, {:enqueue_held, self()})

          receive do
            :release -> Repo.rollback(:probe_finished)
          end
        end)
      end)

    send(enqueuer, :run)
    assert_receive {:enqueue_held, ^enqueuer}

    changeset = IndexBlockSearch.new(%{block_id: ctx.block.id}, schedule_in: 60)

    assert {:ok, %Oban.Job{id: nil, conflict?: true}} =
             Oban.Engines.Basic.insert_job(config, changeset, [])

    refute scheduled_job?(ctx.block)

    send(enqueuer, :release)
    assert_receive {:finished, ^enqueuer, {:error, :probe_finished}}
    refute scheduled_job?(ctx.block)
  end

  test "a backfill waiting for an edit preserves the committed quiet period", ctx do
    parent = self()

    {editor, editor_backend} =
      connection_task(fn ->
        Repo.transaction(fn ->
          {:ok, edited} = Blocks.update_block(ctx.admin, ctx.block, %{"content" => doc("After")})
          send(parent, {:edit_held, self()})

          receive do
            :release -> edited
          end
        end)
      end)

    send(editor, :run)
    assert_receive {:edit_held, ^editor}

    {backfill, backfill_backend} =
      connection_task(fn -> SearchIndex.ensure_scheduled(ctx.block.id, true) end)

    send(backfill, :run)
    await_blocked(backfill_backend, editor_backend)
    send(editor, :release)

    assert_receive {:finished, ^editor, {:ok, edited}}
    assert_receive {:finished, ^backfill, {:ok, :pending}}
    assert Repo.get!(Block, ctx.block.id).search_due_at == edited.search_due_at
    assert Repo.get!(Block, ctx.block.id).content == doc("After")
  end

  test "an edit waiting for a backfill keeps a new deadline and follow-up", ctx do
    {backfill, backfill_backend} =
      connection_task(fn -> SearchIndex.ensure_scheduled(ctx.block.id) end)

    pause_worker_after_lock(backfill)
    send(backfill, :run)
    assert_receive {:row_locked, ^backfill}

    {editor, editor_backend} =
      connection_task(fn ->
        Blocks.update_block(ctx.admin, ctx.block, %{"content" => doc("After")})
      end)

    send(editor, :run)
    await_blocked(editor_backend, backfill_backend)
    send(backfill, :release)

    assert_receive {:finished, ^backfill, {:ok, :enqueued}}
    assert_receive {:finished, ^editor, {:ok, edited}}
    assert Repo.get!(Block, ctx.block.id).search_due_at == edited.search_due_at
    assert scheduled_job?(ctx.block)
    assert {:snooze, _} = perform(ctx.block)
  end

  defp connection_task(fun) do
    parent = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           Sandbox.unboxed_run(Repo, fn ->
             %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
             send(parent, {:connection, self(), backend})

             receive do
               :run -> send(parent, {:finished, self(), fun.()})
             end
           end)
         end},
        id: make_ref()
      )

    assert_receive {:connection, ^pid, backend}
    {pid, backend}
  end

  defp pause_worker_after_lock(worker) do
    handler = {__MODULE__, make_ref()}
    config = %{worker: worker, parent: self()}

    :ok =
      :telemetry.attach(handler, [:athena, :repo, :query], &__MODULE__.pause_after_lock/4, config)

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def pause_after_lock(_event, _measurements, metadata, %{worker: worker, parent: parent}) do
    if self() == worker and String.contains?(metadata.query, "FOR UPDATE") do
      send(parent, {:row_locked, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defp await_blocked(waiter, holder) do
    await_blocked(waiter, holder, System.monotonic_time(:millisecond) + 2_000)
  end

  defp await_blocked(waiter, holder, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $2::integer = ANY(pg_blocking_pids($1::integer))", [waiter, holder])

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected a real PostgreSQL row-lock wait")

      true ->
        await_blocked(waiter, holder, deadline)
    end
  end

  defp scheduled_job?(block) do
    Repo.exists?(
      from j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(IndexBlockSearch) and j.state == "scheduled",
        where: fragment("? ->> 'block_id'", j.args) == ^block.id
    )
  end

  defp mark_overdue(block) do
    Repo.update_all(from(b in Block, where: b.id == ^block.id), set: [search_due_at: past()])
  end

  defp perform(block), do: IndexBlockSearch.perform(%Oban.Job{args: %{"block_id" => block.id}})
  defp past, do: DateTime.add(DateTime.utc_now(), -1)

  defp doc(value) do
    %{
      "type" => "doc",
      "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => value}]}]
    }
  end
end
