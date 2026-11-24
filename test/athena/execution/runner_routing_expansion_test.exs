defmodule Athena.Execution.RunnerRoutingExpansionTest do
  use ExUnit.Case, async: false

  alias Athena.Execution

  for {family, languages} <- [
        script: ~w(python3 javascript typescript),
        compiled: ~w(c cpp go swift rust zig),
        jvm: ~w(java kotlin),
        dotnet: ~w(csharp),
        db: ~w(sql)
      ] do
    test "#{family} registration routes #{Enum.join(languages, ", ")}" do
      family = unquote(family)
      group = {:code_runners, family}
      # The combined development node is registered in every family. Remove
      # those memberships temporarily so a wrong-family fallback cannot pass.
      existing = :pg.get_members(Athena.PG, group)
      Enum.each(existing, &:pg.leave(Athena.PG, group, &1))
      on_exit(fn -> Enum.each(existing, &:pg.join(Athena.PG, group, &1)) end)

      pid = start_supervised!({Agent, fn -> nil end})
      assert :ok = :pg.join(Athena.PG, group, pid)
      on_exit(fn -> :pg.leave(Athena.PG, group, pid) end)

      for language <- unquote(languages) do
        assert Execution.pick_runner(language) == {:ok, pid}
        assert Execution.runner_available?(language)
      end

      assert :ok = :pg.leave(Athena.PG, group, pid)
      refute pid in :pg.get_members(Athena.PG, group)
    end
  end

  test "unknown languages never route to a registered runner" do
    pid = start_supervised!({Agent, fn -> nil end})
    group = {:code_runners, :script}
    :ok = :pg.join(Athena.PG, group, pid)
    on_exit(fn -> :pg.leave(Athena.PG, group, pid) end)
    assert Execution.pick_runner("not-a-language") == :error
    refute Execution.runner_available?("not-a-language")
  end
end
