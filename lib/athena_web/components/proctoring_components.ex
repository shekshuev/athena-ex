defmodule AthenaWeb.ProctoringComponents do
  @moduledoc """
  Shared UI for the academic-integrity ("cheating") risk indicator - used
  both by `AthenaWeb.TeachingLive.GradingDetail` (one submission) and
  `AthenaWeb.TeachingLive.GradingMonitor` (a whole group, live). Generic
  over any submission's `content`: `Athena.Engagement.proctoring_summary/1`
  returns `nil` when there's no proctoring data, so `risk_badge/1` simply
  renders nothing rather than crashing on a non-exam submission.
  """
  use Phoenix.Component
  use AthenaWeb, :html

  alias Athena.Engagement

  @doc """
  A small traffic-light badge summarizing a submission's cheating risk, or
  nothing at all if the submission has no proctoring data.
  """
  attr :content, :map, default: nil

  def risk_badge(assigns) do
    assigns = assign(assigns, :summary, Engagement.proctoring_summary(assigns.content))

    ~H"""
    <.badge :if={@summary} tone={risk_tone(@summary.risk_level)} class="tracking-wide gap-1">
      <.icon name={risk_icon(@summary.risk_level)} class="size-3.5" />
      {risk_label(@summary.risk_level)}
    </.badge>
    """
  end

  @doc """
  Human-readable explanation of how the risk indicator is computed, meant
  to sit above a group-monitoring table or next to a single submission's
  badge - so a teacher isn't left guessing what green/yellow/red means.
  """
  def risk_explanation(assigns) do
    ~H"""
    <div class="p-4 bg-base-200/50 rounded-sm border border-base-300 text-sm text-base-content/70 space-y-2">
      <div class="font-bold text-base-content/80 flex items-center gap-2">
        <.icon name="hero-information-circle" class="size-4" />
        {gettext("How this is measured")}
      </div>
      <p>
        {gettext(
          "While a timed assessment is in progress, we count how many times the student's browser tab loses focus, how many times they press PrintScreen, and how many times they try to copy or cut the question text. Green means zero violations. Yellow means some violations, at or below the assessment's configured limit (\"Allowed Blur Attempts\"). Red means that limit was exceeded - the same limit already used to automatically fail the student's own attempt."
        )}
      </p>
      <p class="text-xs italic">
        {gettext(
          "This only detects what a browser can observe. It cannot see a second device (e.g. a phone), and it cannot catch macOS screenshot shortcuts (Cmd+Shift+3/4/5), which happen entirely outside the browser."
        )}
      </p>
    </div>
    """
  end

  defp risk_tone(:green), do: "success"
  defp risk_tone(:yellow), do: "warning"
  defp risk_tone(:red), do: "error"

  defp risk_icon(:green), do: "hero-check-circle"
  defp risk_icon(:yellow), do: "hero-exclamation-triangle"
  defp risk_icon(:red), do: "hero-x-circle"

  defp risk_label(:green), do: gettext("No violations")
  defp risk_label(:yellow), do: gettext("Some violations")
  defp risk_label(:red), do: gettext("High risk")
end
