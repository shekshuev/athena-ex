defmodule AthenaWeb.TeachingLive.SubmissionLabels do
  @moduledoc """
  Human, translated names for `Athena.Learning.Submission` statuses - one
  place for every grading screen, instead of capitalising the atom.
  """
  use Gettext, backend: AthenaWeb.Gettext

  @doc "Translated label of a submission status."
  @spec status_label(atom()) :: String.t()
  def status_label(:draft), do: gettext("Draft")
  def status_label(:pending), do: gettext("Pending")
  def status_label(:processing), do: gettext("Checking")
  def status_label(:graded), do: gettext("Graded")
  def status_label(:needs_review), do: gettext("Needs review")
  def status_label(:rejected), do: gettext("Rejected")
  def status_label(:accepted), do: gettext("Accepted")
  def status_label(:wrong_answer), do: gettext("Wrong answer")
  def status_label(:time_limit_exceeded), do: gettext("Time limit exceeded")
  def status_label(:memory_limit_exceeded), do: gettext("Memory limit exceeded")
  def status_label(:runtime_error), do: gettext("Runtime error")
  def status_label(:compilation_error), do: gettext("Compilation error")
  def status_label(:system_error), do: gettext("System error")
  def status_label(status), do: status |> to_string() |> String.replace("_", " ")
end
