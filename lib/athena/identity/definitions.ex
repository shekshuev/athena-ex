defmodule Athena.Identity.Definitions do
  @moduledoc "Centralized permissions and policies definitions."

  @permissions ~w"""
  users.read users.update users.delete
  roles.create roles.read roles.update roles.delete
  courses.create courses.read courses.update courses.delete courses.publish
  library.create library.read library.update library.delete
  grading.read grading.update
  enrollments.create enrollments.read enrollments.delete
  instructors.create instructors.read instructors.update instructors.delete
  cohorts.create cohorts.read cohorts.update cohorts.delete
  settings.read settings.update
  files.read files.create files.delete
  admin
  """

  @policies ~w"own_only not_published only_published published_or_owner"

  def permissions, do: @permissions
  def policies, do: @policies
end
