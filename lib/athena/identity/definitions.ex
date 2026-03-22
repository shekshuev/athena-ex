defmodule Athena.Identity.Definitions do
  @moduledoc "Centralized permissions and policies definitions."

  @permissions ~w"""
  users.create users.read users.update users.delete
  roles.create roles.read roles.update roles.delete
  courses.create courses.read courses.update courses.delete courses.publish
  sections.create sections.read sections.update sections.delete
  blocks.create blocks.read blocks.update blocks.delete
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
