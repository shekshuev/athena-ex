defmodule Athena.Repo.Migrations.QuizOptionToTiptap do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE blocks
    SET content = (
      SELECT jsonb_set(
        content,
        '{options}',
        (
          SELECT jsonb_agg(
            CASE
              WHEN jsonb_typeof(opt->'text') = 'string' THEN
                jsonb_set(
                  opt,
                  '{text}',
                  jsonb_build_object(
                    'type', 'doc',
                    'content', jsonb_build_array(
                      jsonb_build_object(
                        'type', 'paragraph',
                        'content', jsonb_build_array(
                          jsonb_build_object('type', 'text', 'text', opt->>'text')
                        )
                      )
                    )
                  )
                )
              ELSE opt
            END
          )
          FROM jsonb_array_elements(content->'options') AS opt
        )
      )
    )
    WHERE type = 'quiz_question'
      AND content ? 'options'
      AND jsonb_typeof(content->'options') = 'array'
      AND jsonb_array_length(content->'options') > 0; -- Игнорим пустые массивы
    """)
  end

  def down do
    execute("""
    UPDATE blocks
    SET content = (
      SELECT jsonb_set(
        content,
        '{options}',
        (
          SELECT jsonb_agg(
            CASE
              WHEN jsonb_typeof(opt->'text') = 'object' THEN
                jsonb_set(
                  opt,
                  '{text}',
                  to_jsonb(
                    COALESCE(
                      opt->'text'->'content'->0->'content'->0->>'text',
                      ''
                    )
                  )
                )
              ELSE opt
            END
          )
          FROM jsonb_array_elements(content->'options') AS opt
        )
      )
    )
    WHERE type = 'quiz_question'
      AND content ? 'options'
      AND jsonb_typeof(content->'options') = 'array'
      AND jsonb_array_length(content->'options') > 0; -- Игнорим пустые массивы
    """)
  end
end
