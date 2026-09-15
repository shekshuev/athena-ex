defmodule Athena.MediaTest do
  use Athena.DataCase, async: true

  alias Athena.Media
  alias Athena.Media.{File, Quota}
  import Athena.Factory

  @default_quota_bytes 100 * 1024 * 1024

  describe "list_files/1" do
    test "should return list of files with flop pagination" do
      insert_list(3, :media_file)

      {:ok, {files, meta}} = Media.list_files(%{page: 1, page_size: 2})

      assert length(files) == 2
      assert meta.total_count == 3
      assert meta.current_page == 1
    end
  end

  describe "list_files/3" do
    test "admin (with \"admin\" permission) sees every file" do
      admin = insert(:account, role: build(:role, permissions: ["admin"]))
      insert_list(3, :media_file)

      {:ok, {files, meta}} = Media.list_files(admin, %{})

      assert meta.total_count == 3
      assert length(files) == 3
    end

    test "user with own_only policy on files.read only sees their own files" do
      role =
        insert(:role, permissions: ["files.read"], policies: %{"files.read" => ["own_only"]})

      user = insert(:account, role: role)

      own_file = insert(:media_file, owner_id: user.id)
      insert(:media_file)

      {:ok, {files, meta}} = Media.list_files(user, %{})

      assert meta.total_count == 1
      assert [%File{id: id}] = files
      assert id == own_file.id
    end

    test "user without files.read sees nothing" do
      role = insert(:role, permissions: [])
      user = insert(:account, role: role)

      insert(:media_file)

      {:ok, {_files, meta}} = Media.list_files(user, %{})

      assert meta.total_count == 0
    end
  end

  describe "list_personal_files/2" do
    test "scopes to the given user's own personal-context files" do
      user = insert(:account)

      own_personal = insert(:media_file, owner_id: user.id, context: :personal)
      insert(:media_file, owner_id: user.id, context: :avatar)
      insert(:media_file, context: :personal)

      {:ok, {files, meta}} = Media.list_personal_files(user, %{})

      assert meta.total_count == 1
      assert [%File{id: id}] = files
      assert id == own_personal.id
    end
  end

  describe "format_bytes/1" do
    test "formats sizes across units" do
      assert Media.format_bytes(500) == "500 B"
      assert Media.format_bytes(2048) == "2.0 KB"
      assert Media.format_bytes(5 * 1024 * 1024) == "5.0 MB"
      assert Media.format_bytes(2 * 1024 * 1024 * 1024) == "2.0 GB"
    end
  end

  describe "list_role_quotas/1" do
    test "returns every role with usage summed across its accounts and quota fallback" do
      admin = insert(:account, role: build(:role, permissions: ["admin"]))

      role_with_quota = insert(:role)
      insert(:media_quota, role_id: role_with_quota.id, limit_bytes: 10_000_000)
      owner_a = insert(:account, role: role_with_quota)
      owner_b = insert(:account, role: role_with_quota)

      role_without_quota = insert(:role)
      owner_c = insert(:account, role: role_without_quota)

      insert(:media_file, owner_id: owner_a.id, context: :personal, size: 1_000_000)
      insert(:media_file, owner_id: owner_b.id, context: :personal, size: 2_000_000)
      insert(:media_file, owner_id: owner_a.id, context: :avatar, size: 9_000_000)
      insert(:media_file, owner_id: owner_c.id, context: :personal, size: 500_000)

      results = Media.list_role_quotas(admin)

      quoted = Enum.find(results, &(&1.role.id == role_with_quota.id))
      assert quoted.used == 3_000_000
      assert quoted.limit == 10_000_000

      unquoted = Enum.find(results, &(&1.role.id == role_without_quota.id))
      assert unquoted.used == 500_000
      assert unquoted.limit == @default_quota_bytes
    end

    test "returns an empty list for a user without files.read" do
      role = insert(:role, permissions: [])
      user = insert(:account, role: role)

      assert Media.list_role_quotas(user) == []
    end
  end

  describe "Quotas management" do
    test "set_quota/2 should insert new quota" do
      role_id = Ecto.UUID.generate()
      limit = 50 * 1024 * 1024

      assert {:ok, %Quota{} = quota} = Media.set_quota(role_id, limit)
      assert quota.role_id == role_id
      assert quota.limit_bytes == limit
    end

    test "set_quota/2 should update existing quota (upsert)" do
      quota = insert(:media_quota)
      new_limit = 999 * 1024

      assert {:ok, updated_quota} = Media.set_quota(quota.role_id, new_limit)
      assert updated_quota.limit_bytes == new_limit
    end

    test "delete_quota/1 should remove quota" do
      quota = insert(:media_quota)

      assert {1, nil} = Media.delete_quota(quota.role_id)
      assert Athena.Repo.get(Quota, quota.role_id) == nil
    end
  end

  describe "get_usage/2 and check_quota/3" do
    test "should calculate usage ONLY for :personal files" do
      owner_id = Ecto.UUID.generate()
      role_id = Ecto.UUID.generate()

      insert(:media_file, owner_id: owner_id, context: :personal, size: 1_000_000)
      insert(:media_file, owner_id: owner_id, context: :personal, size: 1_000_000)

      insert(:media_file, owner_id: owner_id, context: :avatar, size: 5_000_000)
      insert(:media_file, owner_id: owner_id, context: :course_material, size: 5_000_000)

      usage = Media.get_usage(owner_id, role_id)

      assert usage.used == 2_000_000
      assert usage.limit == @default_quota_bytes
    end

    test "should use custom role quota if set" do
      owner_id = Ecto.UUID.generate()
      quota = insert(:media_quota, limit_bytes: 10_000_000)

      insert(:media_file, owner_id: owner_id, context: :personal, size: 5_000_000)

      usage = Media.get_usage(owner_id, quota.role_id)

      assert usage.used == 5_000_000
      assert usage.limit == 10_000_000
    end

    test "check_quota/3 allows upload if under limit" do
      owner_id = Ecto.UUID.generate()
      quota = insert(:media_quota, limit_bytes: 10_000_000)

      insert(:media_file, owner_id: owner_id, size: 8_000_000, context: :personal)

      assert :ok = Media.check_quota(owner_id, quota.role_id, 2_000_000)
    end

    test "check_quota/3 blocks upload if over limit" do
      owner_id = Ecto.UUID.generate()
      quota = insert(:media_quota, limit_bytes: 10_000_000)

      insert(:media_file, owner_id: owner_id, size: 8_000_000, context: :personal)

      assert {:error, :quota_exceeded} = Media.check_quota(owner_id, quota.role_id, 3_000_000)
    end
  end

  describe "S3 Presigned URLs" do
    test "generate_upload_url/2 creates valid PUT url" do
      assert {:ok, url} = Media.generate_upload_url("athena-test", "path/file.jpg")
      assert String.starts_with?(url, "http")
      assert url =~ "athena-test"
      assert url =~ "path/file.jpg"
      assert url =~ "X-Amz-Signature"
    end

    test "generate_download_url/2 creates valid GET url" do
      assert {:ok, url} = Media.generate_download_url("athena-test", "path/doc.pdf")
      assert String.starts_with?(url, "http")
      assert url =~ "X-Amz-Signature"
    end
  end

  describe "Files CRUD" do
    test "create_file/1 inserts file metadata" do
      owner_id = Ecto.UUID.generate()

      attrs = %{
        bucket: "athena-test",
        key: "new/file.png",
        original_name: "image.png",
        mime_type: "image/png",
        size: 2048,
        context: :avatar,
        owner_id: owner_id
      }

      assert {:ok, %File{} = file} = Media.create_file(attrs)
      assert file.key == "new/file.png"
      assert file.context == :avatar
    end

    test "create_file/1 enforces unique constraint on bucket and key" do
      existing_file = insert(:media_file)

      attrs = %{
        bucket: existing_file.bucket,
        key: existing_file.key,
        original_name: "duplicate.pdf",
        mime_type: "application/pdf",
        size: 1024,
        context: :personal,
        owner_id: Ecto.UUID.generate()
      }

      assert {:error, changeset} = Media.create_file(attrs)
      assert "has already been taken" in errors_on(changeset).bucket
    end

    @tag :external
    test "delete_file/1 removes from S3 and DB" do
      file = insert(:media_file)

      on_exit(fn ->
        ExAws.S3.delete_object(file.bucket, file.key) |> ExAws.request()
      end)

      assert {:ok, deleted_file} = Media.delete_file(file)
      assert deleted_file.id == file.id
      assert Athena.Repo.get(File, file.id) == nil
    end
  end
end
