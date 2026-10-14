defmodule Athena.Repo.Migrations.RemoveMaxAttemptsFromBlockContent do
  @moduledoc """
  The `max_attempts` feature (per-block attempt cap on `:quiz_question` and
  `:code` blocks) was removed - it was enforced client-side only and could
  permanently soft-lock the waterline for a `:pass_auto_grade` gate once
  exhausted, with no server-side escape hatch. This strips the now-unused
  `max_attempts` key out of the `content` jsonb on both `blocks` and
  `library_blocks`, so stale values left over from before the removal don't
  linger in the data.

  Irreversible: the stripped values aren't retained, so `down` is a no-op.
  """
  use Ecto.Migration

  @tables ["blocks", "library_blocks"]

  def up do
    for table <- @tables do
      execute("""
      UPDATE #{table}
      SET content = content - 'max_attempts'
      WHERE content ? 'max_attempts';
      """)
    end
  end

  def down do
    :ok
  end
end
