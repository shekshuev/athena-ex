defmodule Athena.Media.StorageTest do
  use ExUnit.Case, async: false

  alias Athena.Media
  alias Athena.Media.Storage

  setup do
    previous_client = Application.get_env(:ex_aws, :http_client)
    previous_media = Application.get_env(:athena, Media)
    Application.put_env(:ex_aws, :http_client, Athena.StorageHttpClient)
    Application.put_env(:athena, Media, bucket: "configured-bucket")
    Process.put(:storage_http_state, %{buckets: %{"configured-bucket" => "{\"Statement\":[]}"}})
    Process.put(:storage_http_calls, [])
    directory = Path.join(System.tmp_dir!(), "athena-policy-tests-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:ex_aws, :http_client, previous_client),
        else: Application.delete_env(:ex_aws, :http_client)

      Application.put_env(:athena, Media, previous_media)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "dry-run inspects the configured bucket without modifying policy" do
    assert [%{bucket: "configured-bucket", applied: false, had_policy: true}] =
             Media.harden_storage!()

    refute Enum.any?(Process.get(:storage_http_calls), fn {method, _} ->
             method in [:delete, :put]
           end)
  end

  test "apply backs up before removing the policy, verifies and can run again", %{
    directory: directory
  } do
    assert [%{applied: true}] = Media.harden_storage!(apply: true, backup_dir: directory)
    [path] = Path.wildcard(Path.join([directory, "*", "*.json"]))
    assert File.read!(path) |> Jason.decode!() |> Map.fetch!("policy") == "{\"Statement\":[]}"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Process.get(:storage_http_state).buckets["configured-bucket"] == nil

    assert [%{applied: true, had_policy: false}] =
             Media.harden_storage!(apply: true, backup_dir: directory)

    assert length(Path.wildcard(Path.join([directory, "*", "*.json"]))) == 2
  end

  test "apply refuses to modify policies without a backup destination" do
    assert_raise KeyError, fn -> Media.harden_storage!(apply: true) end
    refute Enum.any?(Process.get(:storage_http_calls), fn {method, _} -> method == :delete end)
  end

  test "setup creates a missing configured bucket and leaves it private" do
    Process.put(:storage_http_state, %{buckets: %{}})
    assert :ok = Storage.setup!()
    assert Map.has_key?(Process.get(:storage_http_state).buckets, "configured-bucket")
    assert Process.get(:storage_http_state).buckets["configured-bucket"] == nil
  end

  test "storage failures raise instead of reporting successful setup" do
    Process.put(:storage_http_state, %{buckets: %{}, deny: true})
    assert_raise RuntimeError, fn -> Storage.setup!() end
  end
end
