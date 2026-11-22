defmodule AthenaWeb.MediaControllerTest do
  use AthenaWeb.ConnCase, async: true

  import Athena.Factory

  describe "GET /media/*path" do
    test "returns 403 forbidden if user is not authenticated", %{conn: conn} do
      conn = get(conn, "/media/courses/123/secret_image.jpg")

      assert response(conn, 403) =~ "Forbidden"
    end

    test "redirects accessible course media to a presigned S3 URL", %{conn: conn} do
      user = insert(:account)
      course = insert(:course)
      section = insert(:section, course: course)
      key = "courses/#{course.id}/secret_image.jpg"
      insert(:enrollment, account_id: user.id, course_id: course.id)
      insert(:block, section: section, type: :image, content: %{"url" => "/media/#{key}"})

      conn =
        conn
        |> init_test_session(%{"account_id" => user.id})
        |> get("/media/#{key}")

      redirect_url = redirected_to(conn, 302)

      assert redirect_url =~ key
      assert redirect_url =~ "X-Amz-Signature"
    end

    test "does not sign arbitrary unregistered keys for a logged-in account", %{conn: conn} do
      user = insert(:account)

      conn =
        conn |> init_test_session(%{"account_id" => user.id}) |> get("/media/probe/attack.html")

      assert response(conn, 403)
    end
  end

  describe "GET /media/*path for a :personal file" do
    test "the owner can always download their own file", %{conn: conn} do
      owner = insert(:account)
      file = insert(:media_file, owner_id: owner.id, context: :personal)

      conn =
        conn
        |> init_test_session(%{"account_id" => owner.id})
        |> get("/media/#{file.key}")

      assert redirected_to(conn, 302) =~ "X-Amz-Signature"
    end

    test "a stranger is forbidden from downloading a private file", %{conn: conn} do
      owner = insert(:account)
      stranger = insert(:account)
      file = insert(:media_file, owner_id: owner.id, context: :personal, is_public: false)

      conn =
        conn
        |> init_test_session(%{"account_id" => stranger.id})
        |> get("/media/#{file.key}")

      assert response(conn, 403) =~ "Forbidden"
    end

    test "anyone authenticated can download a public file", %{conn: conn} do
      owner = insert(:account)
      other = insert(:account)
      file = insert(:media_file, owner_id: owner.id, context: :personal, is_public: true)

      conn =
        conn
        |> init_test_session(%{"account_id" => other.id})
        |> get("/media/#{file.key}")

      assert redirected_to(conn, 302) =~ "X-Amz-Signature"
    end

    test "an account the file was explicitly shared with can download it", %{conn: conn} do
      owner = insert(:account)
      shared_with = insert(:account)
      file = insert(:media_file, owner_id: owner.id, context: :personal, is_public: false)
      insert(:file_share, media_file: file, account_id: shared_with.id)

      conn =
        conn
        |> init_test_session(%{"account_id" => shared_with.id})
        |> get("/media/#{file.key}")

      assert redirected_to(conn, 302) =~ "X-Amz-Signature"
    end

    test "unauthenticated requests are still forbidden even for a public file", %{conn: conn} do
      owner = insert(:account)
      file = insert(:media_file, owner_id: owner.id, context: :personal, is_public: true)

      conn = get(conn, "/media/#{file.key}")

      assert response(conn, 403) =~ "Forbidden"
    end
  end
end
