defmodule Athena.Identity.Definitions do
  @moduledoc "Centralized permissions and policies definitions."

  @permissions ~w"""
  accounts.create accounts.read accounts.update accounts.delete
  profiles.create profiles.read profiles.update profiles.delete
  courses.create courses.read courses.update courses.delete courses.publish
  lessons.create lessons.read lessons.update lessons.delete
  blocks.execute
  progress.create progress.read progress.update progress.delete
  enrollments.create enrollments.read enrollments.update enrollments.delete
  schedule.create schedule.read schedule.update schedule.delete
  instructors.create instructors.read instructors.update instructors.delete
  cohorts.create cohorts.read cohorts.update cohorts.delete
  files.read files.create files.delete
  admin
  """

  @policies ~w"own_only not_published only_published published_or_owner"

  def permissions, do: @permissions
  def policies, do: @policies
end
