defmodule Mix.Tasks.Athena.Storage.Setup do
  @moduledoc "Creates configured buckets and removes all anonymous bucket policies."
  use Mix.Task
  @shortdoc "Creates private S3/MinIO buckets"

  def run(_args) do
    Mix.Task.run("app.start")
    Athena.Media.setup_storage!()
  end
end
