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
  Pair with `methodology_modal/1` (generic methodology) or
  `submission_breakdown_modal/1` (this submission's actual numbers) for
  the full "Learn more" detail.
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
          "While a timed assessment is in progress, we track several kinds of suspicious browser activity - things like switching tabs or apps, attempting to screenshot or copy the question, and opening the same assessment in more than one tab. Green means nothing suspicious. Yellow means something worth a closer look. Red means it's worth checking in with the student directly."
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

  @doc """
  Button that opens a details modal - shared markup for the two call sites
  below so the button itself always looks the same.
  """
  attr :event, :string, required: true

  def details_button(assigns) do
    ~H"""
    <button type="button" phx-click={@event} class="btn btn-ghost btn-xs gap-1">
      <.icon name="hero-document-magnifying-glass" class="size-3.5" />
      {gettext("Learn more")}
    </button>
    """
  end

  @doc """
  Full methodology walkthrough - every tracked event type, whether it
  counts as direct evidence or a cohort-relative outlier, and the actual
  configured thresholds. Generic/static: does not depend on any one
  submission. Used on the group monitor screen; `submission_breakdown_modal/1`
  is the per-submission counterpart used on the grading-detail screen.
  """
  attr :id, :string, default: "proctoring-methodology-modal"
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}

  def methodology_modal(assigns) do
    assigns = assign(assigns, :t, Engagement.proctoring_thresholds())

    ~H"""
    <.modal
      :if={@show}
      id={@id}
      show={true}
      title={gettext("How the cheating risk indicator is calculated")}
      on_cancel={@on_cancel}
    >
      <div class="space-y-5 text-sm text-base-content/80 max-h-[65vh] overflow-y-auto pr-1 -mr-1">
        <section class="space-y-2">
          <h4 class="font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-exclamation-circle" class="size-4 text-error" />
            {gettext("Direct evidence")}
          </h4>
          <p class="text-base-content/70">
            {gettext(
              "These are counted as-is, with no comparison to other students - there is no legitimate reason for any of them to happen at all during a locked-down question view."
            )}
          </p>
          <ul class="space-y-1.5 list-disc list-inside">
            <li>
              <span class="font-semibold">{gettext("Screenshot attempt")}</span>
              - {gettext(
                "the PrintScreen key was pressed. Windows only - macOS screenshot shortcuts (Cmd+Shift+3/4/5) happen entirely outside the browser and cannot be detected."
              )}
            </li>
            <li>
              <span class="font-semibold">{gettext("Copy / cut attempt")}</span>
              - {gettext(
                "a copy or cut was attempted inside the question text, which is blocked - this means the student tried, not that any text was actually captured."
              )}
            </li>
            <li>
              <span class="font-semibold">{gettext("Multiple tabs")}</span>
              - {gettext(
                "the same exam attempt was detected open in more than one browser tab or window at once."
              )}
            </li>
            <li>
              <span class="font-semibold">{gettext("Tab switches over the allowed limit")}</span>
              - {gettext(
                "the assessment's own configured allowance for switching away from the tab was exceeded."
              )}
            </li>
          </ul>
          <p class="text-xs text-base-content/60">
            {gettext(
              "%{n} or more of these together is enough on its own to mark a submission red.",
              n: @t.hard_evidence_red_threshold
            )}
          </p>
        </section>

        <div class="divider my-1"></div>

        <section class="space-y-2">
          <h4 class="font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-chart-bar" class="size-4 text-warning" />
            {gettext("Behavior compared to the group")}
          </h4>
          <p class="text-base-content/70">
            {gettext(
              "A raw count here means nothing by itself - an anxious student revising an answer many times can look identical, by the numbers, to a student who's cheating. These only count as evidence once they're a genuine statistical outlier relative to everyone else taking this same exam right now, which needs at least %{min} other students to already have reported a value.",
              min: @t.min_sample_size_for_percentile
            )}
          </p>
          <ul class="space-y-1.5 list-disc list-inside">
            <li>
              <span class="font-semibold">{gettext("Tab switches / lost focus, per minute")}</span>
              - {gettext(
                "how often the tab or window lost focus, relative to time spent on the exam."
              )}
            </li>
            <li>
              <span class="font-semibold">{gettext("Answer changes, per minute")}</span>
              - {gettext("how often an answer was revised after first being picked.")}
            </li>
            <li>
              <span class="font-semibold">{gettext("Pasted text ratio")}</span>
              - {gettext(
                "what share of a typed answer's characters arrived via paste rather than typing."
              )}
            </li>
            <li>
              <span class="font-semibold">{gettext("Right-clicks, per minute")}</span>
              - {gettext(
                "right-clicking the question has ordinary innocent causes (inspecting the layout, a misclick), so on its own it is never treated as direct evidence - only an unusually high rate is."
              )}
            </li>
          </ul>
          <p class="text-xs text-base-content/60">
            {gettext(
              "A metric only counts once it's at or above the %{p}th percentile among peers. %{n} or more flagged metrics together is enough to mark a submission red; even one is enough for yellow.",
              p: @t.percentile_outlier_threshold,
              n: @t.behavioral_outliers_red_threshold
            )}
          </p>
        </section>

        <div class="divider my-1"></div>

        <section class="space-y-2">
          <h4 class="font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-signal-slash" class="size-4 text-warning" />
            {gettext("Telemetry silence")}
          </h4>
          <p class="text-base-content/70">
            {gettext(
              "If the browser stops reporting anything at all for longer than expected while the tab should be visible, that absence is itself treated as suspicious - it can mean the tracking script was disabled or tampered with, or simply a crash or lost connection. A gap of %{yellow}+ seconds is enough for yellow, %{red}+ seconds for red - and it self-heals: as soon as reporting resumes, the flag clears on its own.",
              yellow: @t.heartbeat_silence_yellow_threshold_seconds,
              red: @t.heartbeat_silence_red_threshold_seconds
            )}
          </p>
        </section>

        <div class="divider my-1"></div>

        <section class="space-y-1">
          <h4 class="font-bold text-base-content flex items-center gap-2">
            <.icon name="hero-eye-slash" class="size-4 text-base-content/50" />
            {gettext("Known blind spots")}
          </h4>
          <p class="text-xs italic text-base-content/60">
            {gettext(
              "This only detects what a browser can observe. It cannot see a second device (e.g. a phone), and it cannot catch macOS screenshot shortcuts, which happen entirely outside the browser."
            )}
          </p>
          <p class="text-xs italic text-base-content/60">
            {gettext(
              "A telemetry-silence red flag can also mean an ordinary crash or lost connection, not tampering - always check in with the student before treating it as a verdict."
            )}
          </p>
        </section>
      </div>

      <div class="modal-action">
        <button type="button" class="btn btn-primary btn-sm" phx-click={@on_cancel}>
          {gettext("Close")}
        </button>
      </div>
    </.modal>
    """
  end

  @doc """
  Per-submission breakdown - the actual counts, rates and percentiles that
  led to this specific submission's verdict. `nil`/absent fields (a
  submission with no proctoring data, or one saved before this breakdown
  existed) degrade gracefully to zero/"not flagged" rather than crashing.
  """
  attr :id, :string, default: "proctoring-detail-modal"
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :content, :map, required: true

  def submission_breakdown_modal(assigns) do
    detail = Engagement.proctoring_detail(assigns.content) || %{}
    t = Engagement.proctoring_thresholds()

    assigns =
      assigns
      |> assign(:detail, detail)
      |> assign(:t, t)
      |> assign(:hard_evidence_rows, hard_evidence_rows(detail))
      |> assign(:behavioral_rows, behavioral_rows(detail))
      |> assign(:reasons, verdict_reasons(detail, t))

    ~H"""
    <.modal
      :if={@show}
      id={@id}
      show={true}
      title={gettext("Why this submission was flagged")}
      on_cancel={@on_cancel}
    >
      <div class="space-y-5 text-sm text-base-content/80 max-h-[65vh] overflow-y-auto pr-1 -mr-1">
        <div class="flex items-center gap-2">
          <.badge tone={risk_tone(@detail[:risk_level] || :green)} class="tracking-wide gap-1">
            <.icon name={risk_icon(@detail[:risk_level] || :green)} class="size-3.5" />
            {risk_label(@detail[:risk_level] || :green)}
          </.badge>
          <span class="text-xs text-base-content/60">
            {gettext("over %{minutes} min", minutes: format_number(@detail[:elapsed_minutes]))}
          </span>
        </div>

        <p :if={@reasons != []} class="text-base-content/70">
          {gettext("Flagged because:")} {Enum.join(@reasons, "; ")}.
        </p>
        <p :if={@reasons == []} class="text-base-content/70">
          {gettext("Nothing suspicious was observed during this attempt.")}
        </p>

        <section class="space-y-2">
          <h4 class="font-bold text-base-content">{gettext("Direct evidence")}</h4>
          <div class="divide-y divide-base-200">
            <div :for={row <- @hard_evidence_rows} class="flex items-center justify-between py-1.5">
              <span class="text-base-content/70">{row.label}</span>
              <span class={["font-mono font-bold", row.count > 0 && "text-error"]}>
                {row.count}
              </span>
            </div>
          </div>
        </section>

        <section class="space-y-2">
          <h4 class="font-bold text-base-content">{gettext("Behavior compared to the group")}</h4>
          <div class="divide-y divide-base-200">
            <div :for={row <- @behavioral_rows} class="flex items-center justify-between py-1.5 gap-4">
              <span class="text-base-content/70">{row.label}</span>
              <div class="text-right shrink-0">
                <span class="font-mono">{row.formatted_value}</span>
                <span
                  :if={row.percentile}
                  class={[
                    "ml-2 text-xs",
                    row.flagged? && "text-warning font-bold"
                  ]}
                >
                  {gettext("%{p}th percentile", p: format_percentile(row.percentile))}
                </span>
                <span :if={!row.percentile} class="ml-2 text-xs text-base-content/40">
                  {gettext("not enough peer data yet")}
                </span>
              </div>
            </div>
          </div>
        </section>

        <section class="space-y-2">
          <h4 class="font-bold text-base-content">{gettext("Telemetry silence")}</h4>
          <div class="flex items-center justify-between py-1.5">
            <span class="text-base-content/70">
              {gettext("Longest gap with no signal from the browser")}
            </span>
            <span class={[
              "font-mono font-bold",
              (@detail[:heartbeat_silence_seconds] || 0) >=
                @t.heartbeat_silence_yellow_threshold_seconds &&
                "text-warning",
              (@detail[:heartbeat_silence_seconds] || 0) >= @t.heartbeat_silence_red_threshold_seconds &&
                "text-error"
            ]}>
              {@detail[:heartbeat_silence_seconds] || 0}s
            </span>
          </div>
        </section>

        <p class="text-xs text-base-content/50">
          {gettext(
            "Allowed tab switches for this assessment: %{allowed} (exceeded by %{overage}).",
            allowed: @detail[:allowed_blur_attempts] || 0,
            overage: @detail[:blur_overage_count] || 0
          )}
        </p>
      </div>

      <div class="modal-action">
        <button type="button" class="btn btn-primary btn-sm" phx-click={@on_cancel}>
          {gettext("Close")}
        </button>
      </div>
    </.modal>
    """
  end

  defp hard_evidence_rows(detail) do
    counts = detail[:event_counts] || %{}

    [
      %{
        label: gettext("Screenshot attempts (PrintScreen)"),
        count: counts["printscreen_attempt"] || 0
      },
      %{label: gettext("Copy attempts on the question"), count: counts["copy_attempt"] || 0},
      %{label: gettext("Cut attempts on the question"), count: counts["cut_attempt"] || 0},
      %{
        label: gettext("Same exam opened in multiple tabs"),
        count: counts["multi_tab_detected"] || 0
      },
      %{
        label: gettext("Tab switches beyond the allowed limit"),
        count: detail[:blur_overage_count] || 0
      }
    ]
  end

  defp behavioral_rows(detail) do
    rates = detail[:rates] || %{}
    percentiles = detail[:metric_percentiles] || %{}
    outliers = detail[:outlier_metrics] || %{}

    [
      behavioral_row(
        "tab_hidden_per_minute",
        gettext("Tab switches / lost focus (per minute)"),
        rates,
        percentiles,
        outliers,
        :rate
      ),
      behavioral_row(
        "answer_changed_per_minute",
        gettext("Answer changes (per minute)"),
        rates,
        percentiles,
        outliers,
        :rate
      ),
      behavioral_row(
        "paste_ratio",
        gettext("Pasted text ratio"),
        rates,
        percentiles,
        outliers,
        :ratio
      ),
      behavioral_row(
        "right_click_per_minute",
        gettext("Right-clicks (per minute)"),
        rates,
        percentiles,
        outliers,
        :rate
      )
    ]
  end

  defp behavioral_row(key, label, rates, percentiles, outliers, kind) do
    %{
      label: label,
      formatted_value: format_metric(rates[key], kind),
      percentile: percentiles[key],
      flagged?: Map.has_key?(outliers, key)
    }
  end

  defp verdict_reasons(detail, t) do
    []
    |> maybe_add_reason(
      (detail[:hard_evidence_count] || 0) > 0,
      gettext("%{count} piece(s) of direct evidence", count: detail[:hard_evidence_count] || 0)
    )
    |> maybe_add_reason(
      map_size(detail[:outlier_metrics] || %{}) > 0,
      gettext("%{count} unusual behavior metric(s) vs. peers",
        count: map_size(detail[:outlier_metrics] || %{})
      )
    )
    |> maybe_add_reason(
      (detail[:heartbeat_silence_seconds] || 0) >= t.heartbeat_silence_yellow_threshold_seconds,
      gettext("a %{seconds}s gap with no signal from the browser",
        seconds: detail[:heartbeat_silence_seconds] || 0
      )
    )
  end

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons

  defp format_metric(nil, _kind), do: "0"
  defp format_metric(value, :ratio) when is_number(value), do: "#{round(value * 100)}%"
  defp format_metric(value, :rate) when is_number(value), do: format_number(value)

  # Drops a trailing ".0" so a round percentile reads "95th" rather than
  # "95.0th" - the underlying value is only ever rounded to one decimal
  # place (see `Athena.Engagement.Proctoring.evaluate/4`), never truly
  # fractional-looking.
  defp format_percentile(value) when is_float(value) do
    if value == Float.round(value), do: trunc(value) |> to_string(), else: format_number(value)
  end

  defp format_percentile(value), do: to_string(value)

  defp format_number(nil), do: "0"
  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_number(value) when is_integer(value), do: to_string(value)

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
