defmodule AthenaWeb.StudioLive.CompetitionFormComponentTest do
  @moduledoc """
  The author's side of a competition's ranking rules.
  """
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Content
  alias Athena.Content.ScoringRules

  setup %{conn: conn} do
    role =
      insert(:role,
        permissions: [
          "competitions.read",
          "competitions.create",
          "competitions.update",
          "courses.read"
        ]
      )

    author = insert(:account, role: role)
    conn = init_test_session(conn, %{"account_id" => author.id})

    %{conn: conn, author: author}
  end

  defp edit_path(course), do: ~p"/studio/competitions/#{course.id}/edit"

  defp base_params(course, scoring) do
    %{
      "course" => %{
        "title" => course.title,
        "status" => to_string(course.status),
        "scoring" => scoring
      }
    }
  end

  describe "scoring mode" do
    test "the decay settings only appear in dynamic mode", %{conn: conn, author: author} do
      course = insert(:course, type: :competition, owner_id: author.id)

      {:ok, lv, html} = live(conn, edit_path(course))

      refute html =~ "Decay Curve"

      html =
        lv
        |> form("#competition-form", base_params(course, %{"mode" => "dynamic"}))
        |> render_change()

      assert html =~ "Decay Curve"
      assert html =~ "Starting Value"
    end

    test "saves a dynamic rulebook", %{conn: conn, author: author} do
      course = insert(:course, type: :competition, owner_id: author.id)

      {:ok, lv, _html} = live(conn, edit_path(course))

      # The decay fields only exist once dynamic mode is picked, which is
      # how the author reaches them too.
      lv
      |> form("#competition-form", base_params(course, %{"mode" => "dynamic"}))
      |> render_change()

      lv
      |> form(
        "#competition-form",
        base_params(course, %{
          "mode" => "dynamic",
          "initial" => "400",
          "minimum" => "50",
          "decay" => "10",
          "curve" => "logarithmic",
          "solve_threshold" => "80",
          "disqualify_on_rejected" => "false"
        })
      )
      |> render_submit()

      assert {:ok, saved} = Content.get_course(course.id)

      assert %ScoringRules{
               mode: :dynamic,
               initial: 400,
               minimum: 50,
               decay: 10,
               curve: :logarithmic,
               solve_threshold: 80,
               disqualify_on_rejected: false
             } = saved.scoring
    end

    test "a minimum above the starting value is refused", %{conn: conn, author: author} do
      course = insert(:course, type: :competition, owner_id: author.id)

      {:ok, lv, _html} = live(conn, edit_path(course))

      lv
      |> form("#competition-form", base_params(course, %{"mode" => "dynamic"}))
      |> render_change()

      html =
        lv
        |> form(
          "#competition-form",
          base_params(course, %{"mode" => "dynamic", "initial" => "100", "minimum" => "500"})
        )
        |> render_submit()

      assert html =~ "can&#39;t be higher than the initial value"
      assert {:ok, saved} = Content.get_course(course.id)
      assert is_nil(saved.scoring)
    end
  end

  describe "tiebreakers" do
    test "are stored in the order the three selects put them", %{conn: conn, author: author} do
      course = insert(:course, type: :competition, owner_id: author.id)

      {:ok, lv, _html} = live(conn, edit_path(course))

      lv
      |> form(
        "#competition-form",
        base_params(course, %{
          "mode" => "static",
          "tiebreaker_1" => "attempts",
          "tiebreaker_2" => "first_blood",
          "tiebreaker_3" => ""
        })
      )
      |> render_submit()

      assert {:ok, saved} = Content.get_course(course.id)
      assert saved.scoring.tiebreakers == [:attempts, :first_blood]
    end

    test "leaving every select blank falls back to the default order", %{
      conn: conn,
      author: author
    } do
      course = insert(:course, type: :competition, owner_id: author.id)

      {:ok, lv, _html} = live(conn, edit_path(course))

      lv
      |> form(
        "#competition-form",
        base_params(course, %{
          "mode" => "static",
          "tiebreaker_1" => "",
          "tiebreaker_2" => "",
          "tiebreaker_3" => ""
        })
      )
      |> render_submit()

      assert {:ok, saved} = Content.get_course(course.id)
      assert saved.scoring.tiebreakers == [:time, :attempts]
    end

    test "the same tiebreaker twice is refused", %{conn: conn, author: author} do
      course = insert(:course, type: :competition, owner_id: author.id)

      {:ok, lv, _html} = live(conn, edit_path(course))

      html =
        lv
        |> form(
          "#competition-form",
          base_params(course, %{
            "mode" => "static",
            "tiebreaker_1" => "time",
            "tiebreaker_2" => "time",
            "tiebreaker_3" => ""
          })
        )
        |> render_submit()

      assert html =~ "must not repeat the same tiebreaker"
    end
  end

  describe "an unconfigured competition" do
    test "keeps nil scoring rather than being filled in on open", %{conn: conn, author: author} do
      course = insert(:course, type: :competition, owner_id: author.id)

      {:ok, _lv, _html} = live(conn, edit_path(course))

      assert {:ok, reloaded} = Content.get_course(course.id)
      assert is_nil(reloaded.scoring)
    end
  end
end
