bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena-test"

case ExAws.S3.head_bucket(bucket) |> ExAws.request() do
  {:ok, _} ->
    :ok

  {:error, {:http_error, 404, _}} ->
    ExAws.S3.put_bucket(bucket, "us-east-1") |> ExAws.request!()

  error ->
    IO.puts("Error during bucket check: #{inspect(error)}")
end

ExUnit.start(exclude: [:bench], assert_receive_timeout: 1_000)
Ecto.Adapters.SQL.Sandbox.mode(Athena.Repo, :manual)
