defmodule Mix.Tasks.Athena.Storage.Harden do
  @moduledoc """
  Inspects configured storage policies without changing them by default.

      mix athena.storage.harden
      mix athena.storage.harden --apply --backup-dir /secure/policy-backup

  Repeated --bucket selects explicit bucket names. --verify performs real
  signed GET/PUT and anonymous-denial checks on a temporary probe object.
  In production use Athena.Release.harden_storage/1 via the running release.
  """
  use Mix.Task
  @shortdoc "Inspects or removes anonymous storage policies with backups"

  def run(args) do
    {options, [], []} =
      OptionParser.parse(args,
        strict: [apply: :boolean, backup_dir: :string, bucket: :keep, verify: :boolean]
      )

    Mix.Task.run("app.start")
    buckets = Keyword.get_values(options, :bucket)
    opts = Keyword.take(options, [:apply, :backup_dir])
    opts = if buckets == [], do: opts, else: Keyword.put(opts, :buckets, buckets)
    result = Athena.Media.harden_storage!(opts)

    Enum.each(result, fn row ->
      Mix.shell().info("Bucket #{row.bucket}: policy=#{row.had_policy}, applied=#{row.applied}")
      if options[:verify], do: Athena.Media.verify_storage!(row.bucket)
    end)
  end
end
