defmodule Athena.Identity.Definitions do
  @moduledoc "Centralized permissions and policies definitions."

  @permissions ~w"""
  users.create users.read users.update users.delete
  roles.create roles.read roles.update roles.delete
  courses.create courses.read courses.update courses.delete
  library.create library.read library.update library.delete
  grading.read grading.update
  instructors.create instructors.read instructors.update instructors.delete
  cohorts.create cohorts.read cohorts.update cohorts.delete
  settings.read settings.update
  files.read files.create files.delete
  admin
  """

  @policies ~w"own_only"

  def permissions, do: @permissions
  def policies, do: @policies
end
