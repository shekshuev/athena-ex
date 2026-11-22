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
  alias Athena.TimeZones

  @doc """
  A small traffic-light badge summarizing a submission's cheating risk, or
  nothing at all if the submission has no proctoring data.
  """
  attr :content, :map, default: nil

  def risk_badge(assigns) do
    assigns =
      assigns
      |> assign(:summary, Engagement.proctoring_summary(assigns.content))
      |> assign(:review, review_of(assigns.content))

    ~H"""
    <span :if={@summary} class="proctoring-risk-badge inline-flex items-center">
      <%!-- A teacher's decision replaces the automatic colour instead of sitting
      next to it: "no violations" beside "violation confirmed" is a contradiction. --%>
      <span
        :if={@review}
        class="proctoring-review-badge"
        title={gettext("Automatic review priority: %{label}", label: risk_label(@summary.risk_level))}
      >
        <.badge tone={review_tone(@review["status"])} class="tracking-wide gap-1">
          <.icon name={review_icon(@review["status"])} class="size-3.5" />
          {review_label(@review["status"])}
        </.badge>
      </span>
      <.badge
        :if={!@review}
        tone={risk_tone(@summary.risk_level)}
        class="tracking-wide gap-1"
      >
        <.icon name={risk_icon(@summary.risk_level)} class="size-3.5" />
        {risk_label(@summary.risk_level)}
      </.badge>
    </span>
    """
  end

  @doc """
  Warns that a stored verdict predates the points model. Such a submission
  was evaluated by the old rules (no pastes, no time away, nothing without
  15 peers), so its zeros say nothing about what the timeline shows.
  Renders nothing for current verdicts and for submissions without one.
  """
  attr :id, :string, default: "proctoring-legacy-notice"
  attr :content, :map, default: nil

  def legacy_verdict_notice(assigns) do
    assigns = assign(assigns, :legacy?, legacy_verdict?(assigns.content))

    ~H"""
    <div
      :if={@legacy?}
      id={@id}
      class="rounded-sm border border-warning/40 bg-warning/10 p-3 text-xs text-base-content/80"
    >
      {gettext(
        "This result uses earlier scoring rules. It has not been recalculated under the current, more conservative policy. Use the event history and your own review."
      )}
    </div>
    """
  end

  defp legacy_verdict?(%{"risk_level" => level} = content) when not is_nil(level),
    do: content["scoring_version"] != 2

  defp legacy_verdict?(_content), do: false

  @doc """
  The teacher's recorded review of a verdict (who, when, their note), shown
  next to the risk badge so a decision is visible without opening the
  details modal. Renders nothing until a review exists.
  """
  attr :review, :map, default: nil

  def review_summary(assigns) do
    ~H"""
    <div
      :if={@review}
      id="proctoring-review-summary"
      class={[
        "rounded-sm border p-3 text-xs space-y-1",
        if(@review["status"] == "confirmed",
          do: "border-error/30 bg-error/5",
          else: "border-success/30 bg-success/5"
        )
      ]}
    >
      <div class="flex items-center gap-1.5 font-bold text-base-content/80">
        <.icon name={review_icon(@review["status"])} class="size-4" />
        {review_label(@review["status"])}
      </div>
      <p :if={@review["note"] not in [nil, ""]} class="whitespace-pre-wrap text-base-content/80">
        {@review["note"]}
      </p>
      <p class="text-base-content/50">
        {@review["by"]} · {format_review_time(@review["at"])}
      </p>
    </div>
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
          "These observations help instructors review an attempt. Colours indicate review priority, not proof of cheating. Ordinary browser actions and technical problems are recorded without penalty; students receive no monitoring warnings or restrictions."
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
  so the button itself always looks the same.
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
  Full methodology walkthrough - every tracked signal, how many points it
  is worth and the actual configured thresholds. Generic/static: does not
  depend on any one submission. Used on the group monitor screen;
  `submission_breakdown_modal/1` is the per-submission counterpart used on
  the grading-detail screen.
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
      title={gettext("How review priority is calculated")}
      on_cancel={@on_cancel}
      box_class="max-w-2xl"
    >
      <div id="proctoring-methodology" class="space-y-4 text-sm text-base-content/80">
        <p>
          {gettext(
            "Monitoring is visible only to instructors. It never blocks answers, code execution or submission, and never changes a grade."
          )}
        </p>
        <p>
          {gettext(
            "Green means no scored signals; yellow means review recommended; red means priority review, not a confirmed violation. Yellow starts at %{yellow} points and red at %{red} points.",
            yellow: @t.yellow_points,
            red: @t.red_points
          )}
        </p>
        <ul class="list-disc list-inside space-y-2">
          <li>
            {gettext(
              "Multiple sessions: 2 points only after distinct server sessions overlap for at least %{seconds} seconds. Browser tab reports and repeated detections do not add extra points.",
              seconds: @t.concurrent_session_grace_seconds
            )}
          </li>
          <li>
            {gettext(
              "Time away: at most 2 points, including long or repeated absences. Overlapping absences count once."
            )}
          </li>
          <li>
            {gettext(
              "Pasting after returning: at most 2 points for large pastes or an unusually high paste ratio. A large paste starts at %{chars} characters within %{seconds} seconds of returning. The two paste measures never add together.",
              chars: @t.large_paste_chars,
              seconds: @t.paste_away_window_seconds
            )}
          </li>
          <li>
            {gettext(
              "Window layout: at most 1 point after %{seconds} seconds in a small window and at least 3 sideways pointer exits. A narrowed page alone earns no points; it may be a sidebar or developer tools.",
              seconds: @t.split_yellow_seconds
            )}
          </li>
        </ul>
        <p :if={@t.require_server_corroboration_for_red}>
          {gettext(
            "Red also requires a server-confirmed concurrent session. Client-only signals are capped at yellow."
          )}
        </p>
        <p>
          {gettext(
            "Copying, cutting, PrintScreen, input patterns, frequent revisions, right-clicks, network gaps and sampled focus conflicts are recorded for context without points. They have ordinary legitimate causes."
          )}
        </p>
        <p>
          {gettext(
            "Geometry and focus are reported by the browser and can be inaccurate or modified. Brief focus changes and delayed autosaves can explain an answer arriving near unfocused samples. A second display does not prove its use."
          )}
        </p>
        <p>
          {gettext(
            "The browser cannot observe another device or all operating-system screenshot tools. Review the timeline and the student's work before making a decision."
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

  @doc """
  Per-submission breakdown - the points and signals behind this specific
  verdict, every measurement, and (on the second tab) the chronological
  account of what the student did. Fields missing from a submission saved
  before they existed degrade to zero/"not flagged" rather than crashing.
  """
  attr :id, :string, default: "proctoring-detail-modal"
  attr :show, :boolean, default: false
  attr :tab, :string, default: "summary"
  attr :on_cancel, JS, default: %JS{}
  attr :content, :map, required: true
  attr :timeline, :list, default: []
  attr :review_form, :any, default: nil

  def submission_breakdown_modal(assigns) do
    detail = Engagement.proctoring_detail(assigns.content) || %{}
    t = Engagement.proctoring_thresholds()

    assigns =
      assigns
      |> assign(:detail, detail)
      |> assign(:t, t)
      |> assign(:signals, detail[:signals] || [])
      |> assign(:measurements, measurement_rows(detail))
      |> assign(:event_rows, event_rows(detail))

    ~H"""
    <.modal
      :if={@show}
      id={@id}
      show={true}
      title={gettext("Attempt monitoring and event history")}
      on_cancel={@on_cancel}
      box_class="max-w-3xl"
    >
      <div class="tabs tabs-bordered mb-4" role="tablist">
        <button
          type="button"
          id="proctoring-tab-summary"
          role="tab"
          phx-click="proctoring_tab"
          phx-value-tab="summary"
          class={["tab", @tab == "summary" && "tab-active font-bold"]}
        >
          {gettext("Summary")}
        </button>
        <button
          type="button"
          id="proctoring-tab-timeline"
          role="tab"
          phx-click="proctoring_tab"
          phx-value-tab="timeline"
          class={["tab", @tab == "timeline" && "tab-active font-bold"]}
        >
          {gettext("Timeline")}
        </button>
      </div>

      <div class="space-y-5 text-sm text-base-content/80 max-h-[60vh] overflow-y-auto pr-1 -mr-1">
        <%= if @tab == "timeline" do %>
          <.timeline_list entries={@timeline} />
        <% else %>
          <div class="flex items-center gap-2">
            <.badge tone={risk_tone(@detail[:risk_level] || :green)} class="tracking-wide gap-1">
              <.icon name={risk_icon(@detail[:risk_level] || :green)} class="size-3.5" />
              {risk_label(@detail[:risk_level] || :green)}
            </.badge>
            <span :if={@detail[:points]} class="text-xs text-base-content/60">
              {gettext("%{points} points", points: @detail[:points])} · {gettext(
                "over %{minutes} min",
                minutes: format_number(@detail[:elapsed_minutes])
              )}
            </span>
          </div>

          <.legacy_verdict_notice id="proctoring-legacy-notice-modal" content={@content} />

          <.review_panel review={@detail[:review]} form={@review_form} />

          <section class="space-y-2">
            <h4 class="font-bold text-base-content">{gettext("What counted")}</h4>
            <p :if={@signals == []} class="text-base-content/70">
              {gettext("Nothing suspicious was observed during this attempt.")}
            </p>
            <div class="divide-y divide-base-200">
              <div
                :for={signal <- @signals}
                class="flex items-start justify-between gap-4 py-1.5"
              >
                <div>
                  <div class="text-base-content">{signal_label(signal["key"])}</div>
                  <div class="text-xs text-base-content/60">{signal_note(signal)}</div>
                  <span :if={signal["origin"] == "server"} class="text-xs text-base-content/60">
                    {gettext("Observed by the server")}
                  </span>
                  <span :if={signal["origin"] == "client"} class="text-xs text-base-content/60">
                    {gettext("Reported by the browser")}
                  </span>
                </div>
                <span class="font-mono font-bold text-warning shrink-0">+{signal["points"]}</span>
              </div>
            </div>
          </section>

          <section class="space-y-2">
            <h4 class="font-bold text-base-content">{gettext("Everything measured")}</h4>
            <div class="divide-y divide-base-200">
              <div
                :for={row <- @event_rows}
                class="flex items-center justify-between py-1.5"
              >
                <span class="text-base-content/70">{row.label}</span>
                <span class="font-mono">
                  {row.value}
                </span>
              </div>
            </div>
            <div class="divide-y divide-base-200">
              <div
                :for={row <- @measurements}
                class="flex items-center justify-between gap-4 py-1.5"
              >
                <span class="text-base-content/70">{row.label}</span>
                <div class="text-right shrink-0">
                  <span class="font-mono">{row.value}</span>
                  <span
                    :if={row.peers > 0}
                    class={["ml-2 text-xs", row.flagged? && "text-warning font-bold"]}
                  >
                    {gettext("others usually: %{v} (%{n} compared)", v: row.typical, n: row.peers)}
                  </span>
                  <span :if={row.peers == 0} class="ml-2 text-xs text-base-content/40">
                    {gettext("nobody to compare with")}
                  </span>
                </div>
              </div>
            </div>
            <div class="divide-y divide-base-200">
              <div class="flex items-center justify-between py-1.5">
                <span class="text-base-content/70">{gettext("Time away from the exam")}</span>
                <span class="font-mono">
                  {@detail[:away_total_seconds] || 0}s · {gettext("%{n} absences of %{sec}+ s",
                    n: @detail[:away_incidents] || 0,
                    sec: @t.away_incident_min_seconds
                  )}
                </span>
              </div>
              <div
                :if={(@detail[:split_seconds] || 0) + (@detail[:viewport_split_seconds] || 0) > 0}
                class="flex items-center justify-between py-1.5"
              >
                <span class="text-base-content/70">
                  {gettext("Window layout observations")}
                </span>
                <span class="font-mono">
                  {gettext("%{win}s window · %{vp}s narrowed page",
                    win: @detail[:split_seconds] || 0,
                    vp: @detail[:viewport_split_seconds] || 0
                  )}
                </span>
              </div>
              <div
                :if={@detail[:extended_display] == true}
                class="flex items-center justify-between py-1.5"
              >
                <span class="text-base-content/70">{gettext("Second display")}</span>
                <span class="font-mono">{gettext("connected")}</span>
              </div>
              <div class="flex items-center justify-between py-1.5">
                <span class="text-base-content/70">
                  {gettext("Longest gap with no signal from the browser")}
                </span>
                <span class={[
                  "font-mono"
                ]}>
                  {@detail[:heartbeat_silence_seconds] || 0}s
                </span>
              </div>
              <div
                id="proctoring-context-observations"
                class="space-y-2 py-2 text-xs text-base-content/70"
              >
                <p>
                  {gettext(
                    "Context only, without points: %{seconds} seconds outside focus and %{saves} saves or code runs near unfocused samples. Delayed autosaves and ordinary focus changes are possible.",
                    seconds: @detail[:unfocused_seconds] || 0,
                    saves: @detail[:answer_contradictions] || 0
                  )}
                </p>
                <p>
                  {gettext(
                    "Recorded events and technical gaps do not automatically mean a violation. The student receives no monitoring messages."
                  )}
                </p>
              </div>
              <div class="flex items-center justify-between py-1.5">
                <span class="text-base-content/70">{gettext("Longest single paste")}</span>
                <span class="font-mono">
                  {gettext("%{n} characters", n: @detail[:max_paste_chars] || 0)}
                </span>
              </div>
              <div
                :if={(@detail[:typing] || %{})["chars_typed"] not in [nil, 0]}
                class="flex items-center justify-between py-1.5"
              >
                <span class="text-base-content/70">{gettext("Typed / deleted characters")}</span>
                <span class="font-mono">
                  {@detail[:typing]["chars_typed"]} / {@detail[:typing]["chars_deleted"]}
                </span>
              </div>
            </div>
          </section>
        <% end %>
      </div>

      <div class="modal-action">
        <button type="button" class="btn btn-primary btn-sm" phx-click={@on_cancel}>
          {gettext("Close")}
        </button>
      </div>
    </.modal>
    """
  end

  attr :entries, :list, required: true

  defp timeline_list(assigns) do
    ~H"""
    <p :if={@entries == []} class="text-base-content/70">
      {gettext("No notable activity was recorded for this attempt.")}
    </p>
    <div :if={@entries != []} class="space-y-2">
      <p id="proctoring-timeline-origin" class="text-xs text-base-content/70">
        {gettext(
          "Attempt started: %{at}. Elapsed time is +HH:MM:SS from this start; clock times use %{zone}.",
          at: timeline_start(@entries),
          zone: TimeZones.user_timezone()
        )}
      </p>
      <p class="text-xs text-base-content/60">
        {gettext(
          "Browser events are shown when received by the server. Interval starts are estimated from reported durations. Older events may use the browser clock. An event is not a confirmed violation."
        )}
      </p>
      <ol id="proctoring-timeline" class="space-y-1">
        <li
          :for={{entry, index} <- Enum.with_index(@entries)}
          id={"proctoring-event-#{index}"}
          class="flex flex-wrap items-start gap-3 py-2 border-b border-base-200 last:border-0"
        >
          <div class="font-mono text-xs text-base-content/60 w-36 shrink-0">
            <span class="block font-bold">{format_offset(entry.offset)}</span>
            <time
              :if={entry[:at]}
              datetime={DateTime.to_iso8601(entry.at)}
              title={DateTime.to_iso8601(entry.at)}
            >
              {TimeZones.format(entry.at, "%d.%m.%Y %H:%M:%S")}
            </time>
          </div>
          <.icon name={timeline_icon(entry.type)} class="size-4 shrink-0 mt-0.5 text-base-content/50" />
          <span class="text-base-content/80 flex-1 min-w-40">{timeline_label(entry)}</span>
        </li>
      </ol>
    </div>
    """
  end

  attr :review, :map, default: nil
  attr :form, :any, default: nil

  defp review_panel(assigns) do
    ~H"""
    <section
      id="proctoring-review"
      class="space-y-2 p-3 rounded-sm border border-base-300 bg-base-200/40"
    >
      <h4 class="font-bold text-base-content">{gettext("Teacher review")}</h4>
      <div :if={@review} class="text-xs text-base-content/70 space-y-1">
        <div class="flex items-center gap-2">
          <.badge tone={review_tone(@review["status"])}>
            {review_label(@review["status"])}
          </.badge>
          <span>{@review["by"]} · {format_review_time(@review["at"])}</span>
        </div>
        <p :if={@review["note"] not in [nil, ""]} class="text-base-content/80">{@review["note"]}</p>
      </div>
      <.form :if={@form} for={@form} id="proctoring-review-form" phx-submit="review_proctoring">
        <.input
          type="textarea"
          field={@form[:note]}
          rows="2"
          placeholder={gettext("Note (optional)")}
        />
        <div class="flex flex-wrap gap-2 mt-2">
          <button
            type="submit"
            name="status"
            value="dismissed"
            id="proctoring-review-dismiss"
            class="btn btn-sm btn-outline btn-success"
          >
            {gettext("Reviewed - no violation")}
          </button>
          <button
            type="submit"
            name="status"
            value="confirmed"
            id="proctoring-review-confirm"
            class="btn btn-sm btn-outline btn-error"
          >
            {gettext("Confirm violation")}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  # Rows

  defp event_rows(detail) do
    counts = detail[:event_counts] || %{}

    [
      {gettext("PrintScreen key events"), "printscreen_attempt"},
      {gettext("Copy events on the question"), "copy_attempt"},
      {gettext("Cut events on the question"), "cut_attempt"},
      {gettext("Same exam opened in multiple tabs"), "multi_tab_detected"},
      {gettext("Large pastes"), "large_paste"},
      {gettext("Text added without a recent input event"), "bulk_insert"}
    ]
    |> Enum.map(fn {label, key} -> %{label: label, value: counts[key] || 0} end)
  end

  defp measurement_rows(detail) do
    rates = detail[:rates] || %{}
    baselines = detail[:group_baselines] || %{}
    outliers = detail[:outlier_metrics] || %{}

    [
      {"tab_hidden_per_minute", gettext("Tab switches / lost focus (per minute)"), :rate},
      {"answer_changed_per_minute", gettext("Answer changes (per minute)"), :rate},
      {"paste_ratio", gettext("Pasted text ratio"), :ratio},
      {"right_click_per_minute", gettext("Right-clicks (per minute)"), :rate},
      {"mouse_away_seconds_per_minute",
       gettext("Pointer outside the window (seconds per minute)"), :rate}
    ]
    |> Enum.map(fn {key, label, kind} ->
      %{
        label: label,
        value: format_metric(rates[key], kind),
        peers: get_in(baselines, [key, "peers"]) || 0,
        typical: format_metric(get_in(baselines, [key, "median"]), kind),
        flagged?: Map.has_key?(outliers, key)
      }
    end)
  end

  # Labels

  defp signal_label("printscreen_attempt"), do: gettext("PrintScreen key events")
  defp signal_label("copy_attempt"), do: gettext("Copy events on the question")
  defp signal_label("cut_attempt"), do: gettext("Cut events on the question")
  defp signal_label("multi_tab_detected"), do: gettext("Same exam opened in multiple tabs")
  defp signal_label("large_paste"), do: gettext("Large pastes")
  defp signal_label("bulk_insert"), do: gettext("Text added without a recent input event")
  defp signal_label("away"), do: gettext("Time away from the exam")
  defp signal_label("silence_connected"), do: gettext("Browser connected but monitoring silent")
  defp signal_label("silence"), do: gettext("No signal from the browser")
  defp signal_label("split_screen"), do: gettext("Window sharing the screen with another window")

  defp signal_label("answer_while_unfocused"),
    do: gettext("Answers recorded while the page was reported out of focus")

  defp signal_label("unreported_focus_loss"),
    do: gettext("Time out of focus that the browser did not report")

  defp signal_label("machine_typing"), do: gettext("Machine-like typing rhythm")
  defp signal_label("clean_typing"), do: gettext("Long answer typed without any correction")

  defp signal_label("tab_hidden_per_minute"),
    do: gettext("Tab switches / lost focus (per minute)")

  defp signal_label("answer_changed_per_minute"), do: gettext("Answer changes (per minute)")
  defp signal_label("paste_ratio"), do: gettext("Pasted text ratio")
  defp signal_label("right_click_per_minute"), do: gettext("Right-clicks (per minute)")

  defp signal_label("mouse_away_seconds_per_minute"),
    do: gettext("Pointer outside the window (seconds per minute)")

  defp signal_label(other), do: other

  defp signal_note(%{"key" => "away"} = signal),
    do:
      gettext("%{total}s in total, %{n} absences of %{sec}+ s",
        total: signal["value"],
        n: signal["incidents"] || 0,
        sec: Engagement.proctoring_thresholds().away_incident_min_seconds
      )

  defp signal_note(%{"key" => "split_screen", "basis" => "duration"} = signal),
    do:
      gettext(
        "%{win}s with the window sharing the screen, %{vp}s with a narrowed page, pointer left sideways %{n} times",
        win: signal["window_seconds"] || 0,
        vp: signal["viewport_seconds"] || 0,
        n: signal["peeks"] || 0
      )

  defp signal_note(%{"key" => "answer_while_unfocused"} = signal),
    do:
      gettext("%{n} answers recorded while the browser reported the page out of focus",
        n: signal["value"]
      )

  defp signal_note(%{"key" => "unreported_focus_loss"} = signal),
    do: gettext("%{n}s out of focus that no reported absence accounts for", n: signal["value"])

  defp signal_note(%{"key" => key} = signal) when key in ["silence", "silence_connected"],
    do: gettext("longest gap: %{n}s", n: signal["value"])

  defp signal_note(%{"basis" => "group"} = signal),
    do:
      gettext("others usually: %{v}, the bar was %{bar} (%{n} compared)",
        v: format_number(signal["baseline"]),
        bar: format_number(signal["threshold"]),
        n: signal["peers"] || 0
      )

  defp signal_note(%{"basis" => "absolute"} = signal),
    do:
      if((signal["peers"] || 0) > 0,
        do:
          gettext("above the fixed limit of %{bar}, whatever the others do",
            bar: format_number(signal["threshold"])
          ),
        else:
          gettext("above the fixed limit of %{bar} (nobody to compare with)",
            bar: format_number(signal["threshold"])
          )
      )

  # Verdicts stored before the group baseline was reworked.
  defp signal_note(%{"basis" => "percentile"} = signal),
    do:
      gettext("%{p}th percentile among peers",
        p: format_percentile(signal["percentile"])
      )

  defp signal_note(%{"basis" => "fallback"}),
    do: gettext("above the absolute limit (too few peers to compare against)")

  defp signal_note(%{"basis" => "pattern"}), do: gettext("a pattern across the whole answer")
  defp signal_note(%{"value" => value}), do: gettext("occurrences: %{n}", n: value)
  defp signal_note(_signal), do: ""

  defp timeline_label(%{type: :tab_away, duration_ms: ms} = e),
    do: with_fullscreen_note(gettext("Left the tab for %{sec}s", sec: seconds(ms)), e)

  defp timeline_label(%{type: :window_away, duration_ms: ms} = e),
    do: with_fullscreen_note(gettext("Window out of focus for %{sec}s", sec: seconds(ms)), e)

  defp timeline_label(%{type: :fullscreen_exit, duration_ms: ms}),
    do: gettext("Left fullscreen for %{sec}s", sec: seconds(ms))

  defp timeline_label(%{type: :offline_period, duration_ms: ms}),
    do: gettext("Browser was offline for %{sec}s", sec: seconds(ms))

  defp timeline_label(%{type: :mouse_left, duration_ms: ms}),
    do: gettext("Pointer outside the window for %{sec}s", sec: seconds(ms))

  defp timeline_label(%{type: :silence, duration_ms: ms}),
    do: gettext("No signal from the browser for %{sec}s", sec: seconds(ms))

  defp timeline_label(%{type: :silence_connected, duration_ms: ms}),
    do: gettext("Browser connected but monitoring silent for %{sec}s", sec: seconds(ms))

  defp timeline_label(%{type: :split_interval, source: "viewport", duration_ms: ms}),
    do: gettext("Page area narrowed (split view or side panel) for %{sec}s", sec: seconds(ms))

  defp timeline_label(%{type: :split_interval, duration_ms: ms}),
    do:
      gettext("Window occupied part of the screen for %{sec}s; another window is not confirmed",
        sec: seconds(ms)
      )

  defp timeline_label(%{type: :answer_while_unfocused}),
    do:
      gettext(
        "Answer save or code run received near unfocused browser samples; delayed autosave is possible"
      )

  defp timeline_label(%{type: :extended_display}),
    do: gettext("A second display is connected")

  defp timeline_label(%{type: :concurrent_session}),
    do: gettext("Concurrent exam sessions confirmed by the server after the grace period")

  defp timeline_label(%{type: :inert_channel, duration_ms: ms}),
    do: gettext("Only monitoring pings for %{sec}s; the student may be reading", sec: seconds(ms))

  defp timeline_label(%{type: :clock_skew}),
    do: gettext("Browser event timestamps differ from server time")

  defp timeline_label(%{type: :paste_detected, chars: chars, source: source}),
    do:
      gettext("Pasted %{n} characters%{how}",
        n: chars || 0,
        how: if(source == "drop", do: gettext(" (drag and drop)"), else: "")
      )

  defp timeline_label(%{type: :bulk_insert, chars: chars}),
    do:
      gettext(
        "%{n} characters appeared without a recent input event; autofill or assistive input is possible",
        n: chars || 0
      )

  defp timeline_label(%{type: :window_geometry_changed, split: true}),
    do: gettext("Window now occupies part of the screen")

  defp timeline_label(%{type: :window_geometry_changed}),
    do: gettext("Window back to full size")

  defp timeline_label(%{type: :printscreen_attempt} = e),
    do: with_count(gettext("Pressed PrintScreen (screenshot not confirmed)"), e)

  defp timeline_label(%{type: :copy_attempt} = e),
    do: with_count(gettext("Copied question text"), e)

  defp timeline_label(%{type: :cut_attempt} = e),
    do: with_count(gettext("Cut question text"), e)

  defp timeline_label(%{type: :right_click_attempt} = e),
    do: with_count(gettext("Right-clicked the question"), e)

  defp timeline_label(%{type: :multi_tab_detected}),
    do: gettext("Browser reported another exam tab (not server-confirmed)")

  defp timeline_label(%{type: type}), do: to_string(type)

  # Whole seconds, at least 1 - a 1.9 s absence reads "2 s", never "1 s", and
  # nothing that really happened reads "0 s".
  defp seconds(ms), do: max(round((ms || 0) / 1000), 1)

  # One merged absence can also have been a fullscreen exit; say so rather
  # than dropping it from the line.
  defp with_fullscreen_note(label, %{kinds: kinds}) when is_list(kinds) do
    if :fullscreen_exit in kinds,
      do: label <> " " <> gettext("(fullscreen was also exited)"),
      else: label
  end

  defp with_fullscreen_note(label, _entry), do: label

  defp with_count(label, %{count: count}) when count > 1, do: "#{label} ×#{count}"
  defp with_count(label, _entry), do: label

  defp timeline_icon(type) when type in [:tab_away, :window_away, :fullscreen_exit],
    do: "hero-arrow-top-right-on-square"

  defp timeline_icon(type) when type in [:offline_period, :silence], do: "hero-signal-slash"
  defp timeline_icon(:mouse_left), do: "hero-cursor-arrow-rays"

  defp timeline_icon(type) when type in [:paste_detected, :bulk_insert],
    do: "hero-clipboard-document"

  defp timeline_icon(type) when type in [:window_geometry_changed, :split_interval],
    do: "hero-squares-2x2"

  defp timeline_icon(:extended_display), do: "hero-computer-desktop"
  defp timeline_icon(:multi_tab_detected), do: "hero-document-duplicate"
  defp timeline_icon(_type), do: "hero-exclamation-triangle"

  defp review_of(%{"proctoring_review" => %{"status" => _} = review}), do: review
  defp review_of(_content), do: nil

  defp review_tone("confirmed"), do: "error"
  defp review_tone(_status), do: "success"

  defp review_icon("confirmed"), do: "hero-shield-exclamation"
  defp review_icon(_status), do: "hero-shield-check"

  defp format_review_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> TimeZones.format(at, "%Y-%m-%d %H:%M")
      _ -> ""
    end
  end

  defp format_review_time(_iso), do: ""

  defp review_label("confirmed"), do: gettext("Violation confirmed")
  defp review_label(_status), do: gettext("Reviewed - no violation")

  defp timeline_start([%{started_at: at} | _]), do: TimeZones.format(at, "%d.%m.%Y %H:%M:%S")
  defp timeline_start(_), do: "–"

  defp format_offset(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    rest = rem(seconds, 60)

    "+" <>
      Enum.map_join(
        [hours, minutes, rest],
        ":",
        &String.pad_leading(Integer.to_string(&1), 2, "0")
      )
  end

  defp format_metric(nil, _kind), do: "0"
  defp format_metric(value, :ratio) when is_number(value), do: "#{round(value * 100)}%"
  defp format_metric(value, :rate) when is_number(value), do: format_number(value)

  # Drops a trailing ".0" so a round percentile reads "95th" rather than
  # "95.0th" - the underlying value is only ever rounded to one decimal
  # place (see `Athena.Engagement.Proctoring.evaluate/3`).
  defp format_percentile(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> trunc() |> to_string(),
      else: format_number(value)
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

  defp risk_label(:green), do: gettext("No scored signals")
  defp risk_label(:yellow), do: gettext("Review recommended")
  defp risk_label(:red), do: gettext("Priority review")
end
