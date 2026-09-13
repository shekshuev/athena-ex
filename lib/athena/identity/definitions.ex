defmodule Athena.Identity.Definitions do
  @moduledoc "Centralized permissions and policies definitions."

  @permissions ~w"""
  users.create users.read users.update users.delete
  roles.create roles.read roles.update roles.delete
  courses.create courses.read courses.update courses.delete
  library.create library.read library.update library.delete
  characters.create characters.read characters.update characters.delete
  grading.read grading.update
  engagement.create engagement.read engagement.update engagement.delete
  instructors.create instructors.read instructors.update instructors.delete
  cohorts.create cohorts.read cohorts.update cohorts.delete
  settings.read settings.update
  gamification.create gamification.read gamification.update gamification.delete
  files.read files.create files.delete
  system.cache
  admin
  """

  @policies ~w"own_only"

  def permissions, do: @permissions
  def policies, do: @policies
end
