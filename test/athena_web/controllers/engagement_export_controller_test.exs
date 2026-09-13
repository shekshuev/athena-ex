defmodule AthenaWeb.EngagementExportControllerTest do
  use AthenaWeb.ConnCase, async: true

  import Athena.Factory

  describe "GET /teaching/cohorts/:id/engagement/:course_id/export.csv" do
    test "returns 403 forbidden without engagement.read", %{conn: conn} do
      role = insert(:role, permissions: [])
      user = insert(:account, role: role)
      cohort = insert(:cohort)
      course = insert(:course)

      conn =
        conn
        |> init_test_session(%{"account_id" => user.id})
        |> get("/teaching/cohorts/#{cohort.id}/engagement/#{course.id}/export.csv")

      assert response(conn, 403) =~ "Forbidden"
    end

    test "returns a CSV with one row per student per block", %{conn: conn} do
      role = insert(:role, permissions: ["engagement.read"])
      teacher = insert(:account, role: role)

      cohort = insert(:cohort)
      student = insert(:account)
      insert(:cohort_membership, account_id: student.id, cohort_id: cohort.id)

      course = insert(:course)
      section = insert(:section, course: course)
      insert(:block, section: section, type: :text, order: 10)

      conn =
        conn
        |> init_test_session(%{"account_id" => teacher.id})
        |> get("/teaching/cohorts/#{cohort.id}/engagement/#{course.id}/export.csv")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/csv"

      body = response(conn, 200)
      lines = String.split(body, "\n")

      assert length(lines) == 2
      assert Enum.at(lines, 0) =~ "block_id"
      assert body =~ student.id
    end

    test "returns an empty body when there is nothing to export", %{conn: conn} do
      role = insert(:role, permissions: ["engagement.read"])
      teacher = insert(:account, role: role)
      cohort = insert(:cohort)
      course = insert(:course)

      conn =
        conn
        |> init_test_session(%{"account_id" => teacher.id})
        |> get("/teaching/cohorts/#{cohort.id}/engagement/#{course.id}/export.csv")

      assert response(conn, 200) == ""
    end
  end
end
