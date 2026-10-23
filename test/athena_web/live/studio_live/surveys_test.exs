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
    test "shows each survey with its question and response counts", %{conn: conn, user: user} do
      survey = insert(:survey, owner_id: user.id, title: "Mid-course", status: :published)
      insert(:survey_question, survey: survey)
      insert(:survey_question, survey: survey)
      insert(:survey_response, survey: survey)

      {:ok, lv, html} = live(conn, ~p"/studio/surveys")

      assert html =~ "Mid-course"
      # Two counts, in their own columns: 2 questions and 1 response.
      row = lv |> element("##{dom_id(survey)}") |> render()
      assert row =~ ">2<"
      assert row =~ ">1<"
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

    test "marks a published survey that is in no course", %{conn: conn, user: user} do
      stranded = insert(:survey, owner_id: user.id, title: "Stranded", status: :published)
      placed = insert(:survey, owner_id: user.id, title: "Placed", status: :published)

      section = insert(:section, course: insert(:course))
      insert(:block, section: section, type: :survey, content: %{"survey_id" => placed.id})

      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      assert lv |> element("##{dom_id(stranded)}") |> render() =~ "not in any course"
      refute lv |> element("##{dom_id(placed)}") |> render() =~ "not in any course"
    end

    test "a draft is not marked, being not meant to be answerable yet", %{conn: conn, user: user} do
      draft = insert(:survey, owner_id: user.id, title: "Draft one", status: :draft)

      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      refute lv |> element("##{dom_id(draft)}") |> render() =~ "not in any course"
    end

    test "search filters by title", %{conn: conn, user: user} do
      insert(:survey, owner_id: user.id, title: "Pace and workload")
      insert(:survey, owner_id: user.id, title: "Final impressions")

      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      html =
        lv
        |> form("form[phx-change=update_filters]", %{"search" => "workload"})
        |> render_change()

      # The search round-trips through the URL, so the patched render is what
      # carries the filtered list. The patch also carries the paging and sort
      # params, so match on the search rather than the whole query string.
      assert_patch(
        lv,
        ~p"/studio/surveys?#{[search: "workload", page: 1, page_size: 20, order_by: ["inserted_at"], order_directions: ["desc"]]}"
      )

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

  describe "deleting" do
    setup %{conn: conn, user: user} do
      # No response: one of these tests covers the refusal for a survey that
      # has them, and it inserts its own.
      survey = insert(:survey, owner_id: user.id, title: "Old feedback")

      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      %{lv: lv, survey: survey}
    end

    test "deleting asks first, then removes the survey", ctx do
      ctx.lv |> element("#delete-#{ctx.survey.id}") |> render_click()
      assert has_element?(ctx.lv, "#delete-survey-modal.modal-open")

      render_click(ctx.lv, "confirm_delete", %{})

      refute Surveys.get_survey(ctx.survey.id)
      refute render(ctx.lv) =~ "Old feedback"
    end

    test "cancelling keeps it listed", ctx do
      ctx.lv |> element("#delete-#{ctx.survey.id}") |> render_click()
      render_click(ctx.lv, "cancel_delete", %{})

      assert Surveys.get_survey(ctx.survey.id)
      assert render(ctx.lv) =~ "Old feedback"
    end

    test "a survey with responses is kept, with the reason shown", %{conn: conn, user: user} do
      survey = insert(:survey, owner_id: user.id, title: "Answered already")
      insert(:survey_response, survey: survey)

      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      lv |> element("#delete-#{survey.id}") |> render_click()
      html = render_click(lv, "confirm_delete", %{})

      assert html =~ "already has responses"
      assert Surveys.get_survey(survey.id)
    end

    test "a non-owner under own_only cannot delete someone else's survey", %{conn: conn} do
      {conn, _user} =
        sign_in(conn, ["surveys.read", "surveys.delete"], %{"surveys.delete" => ["own_only"]})

      stranger = insert(:survey, owner_id: Ecto.UUID.generate())
      {:ok, lv, _html} = live(conn, ~p"/studio/surveys")

      html = render_click(lv, "delete_click", %{"id" => stranger.id})

      assert html =~ "cannot change that survey"
      assert Surveys.get_survey(stranger.id)
    end
  end

  defp dom_id(survey), do: "surveys-#{survey.id}"
end
