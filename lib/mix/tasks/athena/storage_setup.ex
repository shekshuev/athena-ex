defmodule Mix.Tasks.Athena.Storage.Setup do
  @moduledoc """
  Automatically checks, creates, and configures policies for S3/MinIO buckets.
  """
  use Mix.Task
  require Logger

  @shortdoc "Creates necessary S3/MinIO buckets and applies public policies"

  @default_buckets ["athena"]

  def run(_args) do
    Mix.Task.run("app.start")

    buckets = Application.get_env(:athena, Athena.Media)[:buckets] || @default_buckets

    Logger.info("[Storage.Setup] Starting storage check. Expected buckets: #{inspect(buckets)}")

    Enum.each(buckets, &setup_bucket/1)

    Logger.info("[Storage.Setup] Storage setup completed.")
  end

  defp setup_bucket(bucket) do
    case ExAws.S3.head_bucket(bucket) |> ExAws.request() do
      {:ok, _} ->
        Logger.info("[Storage.Setup] Bucket '#{bucket}' already exists.")
        apply_policy(bucket)

      {:error, {:http_error, 404, _}} ->
        Logger.info("[Storage.Setup] Bucket '#{bucket}' not found. Creating...")

        ExAws.S3.put_bucket(bucket, "") |> ExAws.request!()

        Logger.info("[Storage.Setup] Bucket '#{bucket}' successfully created.")
        apply_policy(bucket)

      error ->
        Logger.error("[Storage.Setup] Error checking bucket '#{bucket}': #{inspect(error)}")
    end
  end

  defp apply_policy(bucket) do
    Logger.info("[Storage.Setup] Applying public read policy to '#{bucket}/public/*'...")

    policy = %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Sid" => "PublicReadGetObject",
          "Effect" => "Allow",
          "Principal" => "*",
          "Action" => ["s3:GetObject"],
          "Resource" => ["arn:aws:s3:::#{bucket}/public/*"]
        }
      ]
    }

    policy_json = Jason.encode!(policy)

    case ExAws.S3.put_bucket_policy(bucket, policy_json) |> ExAws.request() do
      {:ok, _} ->
        Logger.info("[Storage.Setup] Policy successfully applied.")

      error ->
        Logger.error("[Storage.Setup] Failed to apply policy: #{inspect(error)}")
    end
  end
end
