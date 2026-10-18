defmodule Athena.Content.SurveyUsageTest do
  @moduledoc """
  Where a survey is actually used.

  A survey reaches students through a `:survey` block in a course and nowhere
  else, so "which courses is this in" is the difference between a published
  survey people can answer and one that sits there collecting nothing.
  """
  use Athena.DataCase, async: true

  import Athena.Factory

  alias Athena.Content

  defp survey_block(section, survey_id) do
    insert(:block, section: section, type: :survey, content: %{"survey_id" => survey_id})
  end

  describe "courses_using_survey/1" do
    test "finds the courses and sections a survey sits in" do
      survey = insert(:survey)
      course = insert(:course, title: "Databases")
      section = insert(:section, course: course, title: "Week 1")
      block = survey_block(section, survey.id)

      assert [place] = Content.courses_using_survey(survey.id)

      assert place.course_id == course.id
      assert place.course_title == "Databases"
      assert place.section_title == "Week 1"
      assert place.block_id == block.id
    end

    test "a survey in no course comes back empty" do
      survey = insert(:survey)

      # Which is exactly the state worth warning about: published and
      # unanswerable, with silence as the only symptom.
      assert Content.courses_using_survey(survey.id) == []
    end

    test "lists every placement when a survey is reused" do
      survey = insert(:survey)

      for title <- ["Databases", "Algorithms"] do
        course = insert(:course, title: title)
        section = insert(:section, course: course)
        survey_block(section, survey.id)
      end

      places = Content.courses_using_survey(survey.id)

      assert length(places) == 2
      assert Enum.map(places, & &1.course_title) == ["Algorithms", "Databases"]
    end

    test "ignores blocks pointing at a different survey" do
      survey = insert(:survey)
      other = insert(:survey)
      section = insert(:section, course: insert(:course))

      survey_block(section, other.id)

      assert Content.courses_using_survey(survey.id) == []
    end

    test "ignores non-survey blocks" do
      survey = insert(:survey)
      section = insert(:section, course: insert(:course))

      insert(:block, section: section, type: :text, content: %{"survey_id" => survey.id})

      assert Content.courses_using_survey(survey.id) == []
    end

    test "leaves out a deleted course" do
      survey = insert(:survey)
      course = insert(:course, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      section = insert(:section, course: course)
      survey_block(section, survey.id)

      assert Content.courses_using_survey(survey.id) == []
    end

    test "reports an unpublished course so the author knows why it is quiet" do
      survey = insert(:survey)
      course = insert(:course, status: :draft)
      section = insert(:section, course: course)
      survey_block(section, survey.id)

      assert [%{course_status: :draft}] = Content.courses_using_survey(survey.id)
    end
  end

  describe "survey_usage_counts/1" do
    test "counts placements per survey in one query" do
      used_twice = insert(:survey)
      used_once = insert(:survey)
      unused = insert(:survey)

      section = insert(:section, course: insert(:course))
      other_section = insert(:section, course: insert(:course))

      survey_block(section, used_twice.id)
      survey_block(other_section, used_twice.id)
      survey_block(section, used_once.id)

      counts = Content.survey_usage_counts([used_twice.id, used_once.id, unused.id])

      assert counts[used_twice.id] == 2
      assert counts[used_once.id] == 1
      # Absent rather than zero: the caller defaults, and a row per unused
      # survey would be a query doing the caller's work.
      refute Map.has_key?(counts, unused.id)
    end

    test "an empty list needs no query" do
      assert Content.survey_usage_counts([]) == %{}
    end
  end
end
