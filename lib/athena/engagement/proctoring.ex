defmodule Athena.Engagement.Proctoring do
  @moduledoc """
  Turns raw `Athena.Engagement.ProctoringMonitor` counts into the
  `cheat_count`/`proctoring` fields persisted on `Submission.content`, and
  the risk-level classification shown to teachers.

  Deliberately generic over any submission - a submission with no
  `cheat_count` key in its content (i.e. everything except
  `quiz_exam`/`ticket_exam` in this iteration) is simply "no data", not an
  error, so callers can call `summary/1` on any submission's content
  without special-casing the block type.
  """

  alias Athena.Engagement.ProctoringMonitor

  @type risk_level :: :green | :yellow | :red

  @doc """
  Builds the `content` fields to merge into a `Submission.content` map at
  the moment an exam attempt is finalized. `allowed_blur_attempts` is the
  block's own configured threshold (`block.content["allowed_blur_attempts"]`)
  - reused here so the teacher's risk indicator and the student-facing
  "Assessment Failed (Violations)" state always agree on the same cutoff.
  """
  @spec build_content_fields(ProctoringMonitor.counts(), non_neg_integer()) :: map()
  def build_content_fields(counts, allowed_blur_attempts) do
    cheat_count =
      counts.tab_hidden + counts.printscreen_attempt + counts.copy_attempt + counts.cut_attempt

    %{
      "cheat_count" => cheat_count,
      "proctoring" => %{
        "tab_hidden" => counts.tab_hidden,
        "printscreen_attempt" => counts.printscreen_attempt,
        "copy_attempt" => counts.copy_attempt,
        "cut_attempt" => counts.cut_attempt,
        "allowed_blur_attempts" => allowed_blur_attempts,
        "risk_level" => Atom.to_string(risk_level(cheat_count, allowed_blur_attempts))
      }
    }
  end

  @spec risk_level(non_neg_integer(), non_neg_integer()) :: risk_level()
  def risk_level(0, _threshold), do: :green
  def risk_level(cheat_count, threshold) when cheat_count >= threshold, do: :red
  def risk_level(_cheat_count, _threshold), do: :yellow

  @doc """
  `nil` when the submission has no proctoring data at all (not an exam
  block, or an exam attempt that predates this feature) - callers use this
  to decide whether to render the risk indicator at all.
  """
  @spec summary(map() | nil) ::
          %{
            cheat_count: integer(),
            breakdown: map(),
            risk_level: risk_level()
          }
          | nil
  def summary(content) when is_map(content) do
    case content["cheat_count"] do
      nil ->
        nil

      cheat_count ->
        proctoring = content["proctoring"] || %{}
        threshold = proctoring["allowed_blur_attempts"] || 3

        %{
          cheat_count: cheat_count,
          breakdown: proctoring,
          risk_level: risk_level(cheat_count, threshold)
        }
    end
  end

  def summary(_), do: nil
end
