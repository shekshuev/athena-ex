defmodule Athena.Repo.Migrations.MoveSqlSandboxFieldsOutOfBody do
  @moduledoc """
  SQL `:code` blocks used to stash their sandbox config (`setup_sql`,
  `solution_sql`, `check_sql`, `evaluation_mode`) inside `content.body` -
  the exact same key every block type (including `:code` itself) uses to
  store its rich-text instructions doc. Editing the instructions overwrote
  `body` wholesale and silently wiped the sandbox config.

  This moves those four fields to top-level `content` keys (matching the
  `Athena.Content.CodeChallenge` schema fix), reusing the existing
  `solution_code` field for the SQL reference solution instead of a
  separate `solution_sql`, and strips the old keys back out of `body` so
  it goes back to holding only the instructions doc.
  """
  use Ecto.Migration

  @tables ["blocks", "library_blocks"]

  def up do
    for table <- @tables do
      execute("""
      UPDATE #{table}
      SET content =
        (content
          || jsonb_build_object(
               'setup_sql', COALESCE(content->'body'->>'setup_sql', content->>'setup_sql', ''),
               'solution_code',
                 COALESCE(
                   content->'body'->>'solution_sql',
                   content->>'solution_code',
                   ''
                 ),
               'check_sql', COALESCE(content->'body'->>'check_sql', content->>'check_sql', ''),
               'evaluation_mode',
                 COALESCE(
                   content->'body'->>'evaluation_mode',
                   content->>'evaluation_mode',
                   'query_result'
                 )
             )
        )
        || jsonb_build_object(
             'body',
             (content->'body') - 'setup_sql' - 'solution_sql' - 'check_sql' - 'evaluation_mode'
           )
      WHERE content->>'language' = 'sql'
        AND jsonb_typeof(content->'body') = 'object';
      """)
    end
  end

  def down do
    for table <- @tables do
      execute("""
      UPDATE #{table}
      SET content =
        (content - 'setup_sql' - 'check_sql' - 'evaluation_mode')
        || jsonb_build_object(
             'body',
             COALESCE(content->'body', '{}'::jsonb)
             || jsonb_build_object(
                  'setup_sql', COALESCE(content->>'setup_sql', ''),
                  'solution_sql', COALESCE(content->>'solution_code', ''),
                  'check_sql', COALESCE(content->>'check_sql', ''),
                  'evaluation_mode', COALESCE(content->>'evaluation_mode', 'query_result')
                )
           )
      WHERE content->>'language' = 'sql';
      """)
    end
  end
end
