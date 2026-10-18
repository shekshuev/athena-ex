defmodule AthenaWeb.StudioLive.SurveysTest do
  @moduledoc """
  The survey list: scoping, creation, search and archiving.
  """
  use AthenaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Athena.Factory

  alias Athena.Surveys

  defp sign_in(conn, permissions, policies \\ %{}) do
    user = insert(:account, role: insert(:role, permissions: permissions, policies: policies))
    {init_test_session(conn, %{"account_id" => user.id}), user}
  end

  setup %{conn: conn} do
    {conn, user} =
      sign_in(conn, [
        "surveys.read",
        "surveys.create",
        "surveys.update",
        "surveys.delete"
      ])

    %{conn: conn, user: user}
  end

  describe "access" do
    test "surveys.read is required", %{conn: conn} do
      {conn, _user} = sign_in(conn, [])

      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/studio/surveys")
    end

    test "own_only shows only the user's own surveys", %{conn: conn} do
      {conn, user} =
        sign_in(conn, ["surveys.read"], %{"surveys.read" => ["own_only"]})

      mine = insert(:survey, owner_id: user.id, title: "My feedback form")
      theirs = insert(:survey, owner_id: Ecto.UUID.generate(), title: "Somebody else's")

      {:ok, _lv, html} = live(conn, ~p"/studio/surveys")

      assert html =~ mine.title
      refute html =~ theirs.title
    end
  end

  describe "listing" do
    test "shows each survey with its status and counts", %{conn: conn, user: user} do
      survey = insert(:survey, owner_id: user.id, title: "Mid-course", status: :published)
      insert(:survey_question, survey: survey)
      insert(:survey_question, survey: survey)
      insert(:survey_response, survey: survey)

      {:ok, _lv, html} = live(conn, ~p"/studio/surveys")

      assert html =~ "Mid-course"
      assert html =~ "Published"
      assert html =~ "2 questions"
      assert html =~ "1 response"
    end

    test "an empty list shows an empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio/surveys")

      assert html =~ "No surveys yet"
    end

    test "a survey with responses offers Open rather than Edit", %{conn: conn, user: user} do
      editable = insert(:survey, owner_id: user.id, title: "Still editable")
      locked = insert(:survey, owner_id: user.id, title: "Locked one")
      insert(:survey_response, survey: locked)

      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      assert lv |> element("##{dom_id(editable)}") |> render() =~ "Edit"
      assert lv |> element("##{dom_id(locked)}") |> render() =~ "Open"
    end

    test "search filters by title", %{conn: conn, user: user} do
      insert(:survey, owner_id: user.id, title: "Pace and workload")
      insert(:survey, owner_id: user.id, title: "Final impressions")

      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      html =
        lv
        |> form("form[phx-change=search]", %{"search" => "workload"})
        |> render_change()

      # The search round-trips through the URL, so the patched render is what
      # carries the filtered list.
      assert_patched(lv, ~p"/studio/surveys?search=workload")
      assert render(lv) =~ "Pace and workload"
      refute render(lv) =~ "Final impressions"
      assert html
    end
  end

  describe "creating" do
    test "the new-survey modal opens on its own route", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio/surveys/new")

      assert has_element?(lv, "#new-survey-modal.modal-open")
      assert has_element?(lv, "#survey-form")
    end

    test "creating opens the builder for the new survey", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/studio/surveys/new")

      {:error, {:live_redirect, %{to: path}}} =
        lv
        |> form("#survey-form", %{"survey" => %{"title" => "How is it going?"}})
        |> render_submit()

      assert path =~ ~r"^/studio/surveys/[0-9a-f-]+/builder$"

      {:ok, {[survey], _meta}} = Surveys.list_surveys_for_user(user)
      assert survey.title == "How is it going?"
      assert survey.owner_id == user.id
    end

    test "a blank title is reported instead of creating", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/studio/surveys/new")

      html =
        lv
        |> form("#survey-form", %{"survey" => %{"title" => ""}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert {:ok, {[], _meta}} = Surveys.list_surveys_for_user(user)
    end

    test "without surveys.create the button is gone and the event is refused", %{conn: conn} do
      {conn, _user} = sign_in(conn, ["surveys.read"])
      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      refute has_element?(lv, "#new-survey")

      html = render_submit(lv, "create", %{"survey" => %{"title" => "Sneaky"}})

      assert html =~ "cannot create surveys"
      assert Athena.Repo.aggregate(Athena.Surveys.Survey, :count) == 0
    end
  end

  describe "archiving" do
    setup %{conn: conn, user: user} do
      survey = insert(:survey, owner_id: user.id, title: "Old feedback")
      insert(:survey_response, survey: survey)

      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      %{lv: lv, survey: survey}
    end

    test "archiving asks first, then hides the survey but keeps responses", ctx do
      ctx.lv |> element("#archive-#{ctx.survey.id}") |> render_click()
      assert has_element?(ctx.lv, "#archive-survey-modal.modal-open")

      render_click(ctx.lv, "confirm_archive", %{})

      assert Surveys.get_survey(ctx.survey.id).status == :archived
      assert length(Surveys.list_responses(ctx.survey.id)) == 1
      refute render(ctx.lv) =~ "Old feedback"
    end

    test "cancelling keeps it listed", ctx do
      ctx.lv |> element("#archive-#{ctx.survey.id}") |> render_click()
      render_click(ctx.lv, "cancel_archive", %{})

      assert Surveys.get_survey(ctx.survey.id).status == :draft
      assert render(ctx.lv) =~ "Old feedback"
    end

    test "archived surveys are hidden until asked for, then restorable", ctx do
      {:ok, _} = Surveys.archive_survey(ctx.survey)

      {:ok, lv, html} = live(ctx.conn, ~p"/studio/surveys")
      refute html =~ "Old feedback"

      html = lv |> element("#toggle-archived") |> render_click()
      assert html =~ "Old feedback"

      render_click(lv, "restore", %{"id" => ctx.survey.id})
      assert Surveys.get_survey(ctx.survey.id).status == :draft
    end

    test "a non-owner under own_only cannot archive someone else's survey", %{conn: conn} do
      {conn, _user} =
        sign_in(conn, ["surveys.read", "surveys.delete"], %{"surveys.delete" => ["own_only"]})

      stranger = insert(:survey, owner_id: Ecto.UUID.generate())
      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      html = render_click(lv, "archive_click", %{"id" => stranger.id})

      assert html =~ "cannot change that survey"
      assert Surveys.get_survey(stranger.id).status == :draft
    end
  end

  defp dom_id(survey), do: "surveys-#{survey.id}"
end
