defmodule Athena.Execution.Database.Deadline do
  @moduledoc "Independent server cancellation, including when the runner task exits during a query."

  def run(adapter, identity, milliseconds, callback) do
    owner = self()

    watchdog =
      spawn(fn ->
        ref = Process.monitor(owner)

        receive do
          :finished -> Process.demonitor(ref, [:flush])
          {:DOWN, ^ref, :process, ^owner, _} -> adapter.cancel(identity)
        after
          milliseconds -> adapter.cancel(identity)
        end
      end)

    try do
      callback.()
    after
      send(watchdog, :finished)
    end
  end
end
