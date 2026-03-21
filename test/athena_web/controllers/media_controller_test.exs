defmodule AthenaWeb.MediaControllerTest do
  use AthenaWeb.ConnCase, async: true

  import Athena.Factory

  describe "GET /media/*path" do
    test "returns 403 forbidden if user is not authenticated", %{conn: conn} do
      conn = get(conn, "/media/courses/123/secret_image.jpg")

      assert response(conn, 403) =~ "Forbidden"
    end

    test "redirects to presigned S3 URL if user is authenticated", %{conn: conn} do
      user = insert(:account)

      conn =
        conn
        |> init_test_session(%{"account_id" => user.id})
        |> get("/media/courses/123/secret_image.jpg")

      redirect_url = redirected_to(conn, 302)

      assert redirect_url =~ "courses/123/secret_image.jpg"
      assert redirect_url =~ "X-Amz-Signature"
    end
  end
end
