defmodule Athena.Workers.MediaCleanupTest do
  use Athena.DataCase, async: true

  alias Athena.Workers.MediaCleanup
  alias Athena.Media.File
  import Athena.Factory

  describe "perform/1" do
    @tag :external
    test "deletes orphaned course files but keeps active and non-course files" do
      active_file = insert(:media_file, key: "courses/123/active.jpg", context: :course_material)
      insert(:block, content: %{"url" => "/media/courses/123/active.jpg"})

      orphaned_file =
        insert(:media_file, key: "courses/123/orphan.jpg", context: :course_material)

      avatar_file = insert(:media_file, key: "avatars/456/me.jpg", context: :avatar)

      assert :ok = MediaCleanup.perform(%Oban.Job{})
      assert Repo.get(File, active_file.id) != nil
      assert Repo.get(File, avatar_file.id) != nil
      assert Repo.get(File, orphaned_file.id) == nil
    end

    @tag :external
    test "keeps submission files referenced in Submission.content[file_urls]" do
      file_in_submission =
        insert(:media_file,
          key: "courses/abc/report.pdf",
          context: :submission,
          original_name: "report.pdf"
        )

      insert(:submission,
        content: %{
          "type" => "file_assignment",
          "file_urls" => ["/media/courses/abc/report.pdf"]
        }
      )

      orphaned_submission_file =
        insert(:media_file,
          key: "courses/abc/old_report.pdf",
          context: :submission,
          original_name: "old_report.pdf"
        )

      assert :ok = MediaCleanup.perform(%Oban.Job{})
      assert Repo.get(File, file_in_submission.id) != nil
      assert Repo.get(File, orphaned_submission_file.id) == nil
    end

    @tag :external
    test "handles files referenced in both Block and Submission" do
      shared_file =
        insert(:media_file,
          key: "shared/resource.zip",
          context: :course_material,
          original_name: "resource.zip"
        )

      insert(:block, content: %{"attachment_url" => "/media/shared/resource.zip"})

      insert(:submission,
        content: %{
          "type" => "file_assignment",
          "file_urls" => ["/media/shared/resource.zip"]
        }
      )

      assert :ok = MediaCleanup.perform(%Oban.Job{})
      assert Repo.get(File, shared_file.id) != nil
    end

    @tag :external
    test "correctly matches file key with /media/ prefix in Submission.content" do
      file =
        insert(:media_file,
          key: "uploads/course_xyz/assignment.pdf",
          context: :submission,
          original_name: "assignment.pdf"
        )

      insert(:submission,
        content: %{
          "type" => "file_assignment",
          "file_urls" => ["/media/uploads/course_xyz/assignment.pdf"]
        }
      )

      assert :ok = MediaCleanup.perform(%Oban.Job{})
      assert Repo.get(File, file.id) != nil
    end

    @tag :external
    test "deletes submission file when no references exist in Block or Submission" do
      file =
        insert(:media_file,
          key: "orphaned/submission_file.docx",
          context: :submission,
          original_name: "submission_file.docx"
        )

      assert :ok = MediaCleanup.perform(%Oban.Job{})
      assert Repo.get(File, file.id) == nil
    end

    @tag :external
    test "ignores files with context :personal and :avatar" do
      personal_file = insert(:media_file, key: "personal/doc.pdf", context: :personal)
      avatar_file = insert(:media_file, key: "avatars/user.png", context: :avatar)

      assert :ok = MediaCleanup.perform(%Oban.Job{})
      assert Repo.get(File, personal_file.id) != nil
      assert Repo.get(File, avatar_file.id) != nil
    end

    @tag :external
    test "handles multiple file_urls in a single submission" do
      file1 = insert(:media_file, key: "multi/file1.pdf", context: :submission)
      file2 = insert(:media_file, key: "multi/file2.pdf", context: :submission)
      file3 = insert(:media_file, key: "multi/file3.pdf", context: :submission)

      insert(:submission,
        content: %{
          "type" => "file_assignment",
          "file_urls" => [
            "/media/multi/file1.pdf",
            "/media/multi/file2.pdf"
          ]
        }
      )

      assert :ok = MediaCleanup.perform(%Oban.Job{})

      assert Repo.get(File, file1.id) != nil
      assert Repo.get(File, file2.id) != nil
      assert Repo.get(File, file3.id) == nil
    end

    @tag :external
    test "does not delete file if referenced in any submission (even by different user)" do
      file =
        insert(:media_file, key: "shared/team_report.xlsx", context: :submission)

      insert(:submission,
        account_id: Ecto.UUID.generate(),
        content: %{
          "type" => "file_assignment",
          "file_urls" => ["/media/shared/team_report.xlsx"]
        }
      )

      assert :ok = MediaCleanup.perform(%Oban.Job{})
      assert Repo.get(File, file.id) != nil
    end

    @tag :external
    test "logs deletion of orphaned files" do
      orphan = insert(:media_file, key: "to_delete.zip", context: :course_material)

      ExUnit.CaptureLog.capture_log(fn ->
        :ok = MediaCleanup.perform(%Oban.Job{})
      end)

      assert Repo.get(File, orphan.id) == nil
    end

    @tag :external
    test "handles empty database gracefully" do
      assert :ok = MediaCleanup.perform(%Oban.Job{})
    end
  end
end
