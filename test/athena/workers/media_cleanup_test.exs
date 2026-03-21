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
  end
end
