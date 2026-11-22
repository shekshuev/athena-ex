defmodule Athena.Engagement.Layout do
  @moduledoc """
  Server-side reading of the exam window's layout, built from raw geometry
  samples the browser attaches to each heartbeat.

  The browser used to decide for itself that "the window shares the screen"
  and send only that verdict, which a modified client can simply never send.
  Now it sends raw numbers (outer/inner size, screen size, DPR, focus,
  visibility, fullscreen) every couple of seconds, and the *server*:

    * classifies each sample (see `classify/2`);
    * measures how long each state lasted using its own receipt times, so
      the client can neither inflate nor hide durations - the time covered
      by one heartbeat is capped by the real time since the previous one;
    * keeps the intervals (they reach the teacher's timeline as
      `split_interval` incidents);
    * cross-checks "visible but not focused" time against the absences the
      same browser reported through its events (see
      `Athena.Engagement.Proctoring`), which exposes suppressed
      blur/focus listeners.

  Causes of a split:

    * `"window"` - the browser window itself occupies only part of the
      screen (snapped/tiled next to another window);
    * `"viewport"` - the window is full size but the page area was narrowed
      (split view / side-by-side tabs, a side panel). Measured against the
      widest viewport seen so far, normalised by zoom. A docked DevTools
      narrows the viewport the same way, so this cause is weighed at half.

  Everything the browser sends is still self-reported; the server-observed
  part is the time accounting and the cross-checks. State is plain data so
  it can be checkpointed with the rest of the monitor.
  """

  @max_samples 10
  @max_dim 20_000
  @sample_interval_s 2
  @max_delta_s 30
  @sample_ms @sample_interval_s * 1000
  @max_pending 20
  @max_contradiction_incidents 3
  @min_interval_s 5

  @modes ["normal", "window", "viewport"]

  @type t :: %{
          baseline: float() | nil,
          baseline_aw: non_neg_integer() | nil,
          mode: String.t(),
          run_started_ms: integer() | nil,
          run_seconds: float(),
          last_at_ms: integer() | nil,
          window_s: float(),
          viewport_s: float(),
          unfocused_s: float(),
          unfocused_run_s: float(),
          peeks: non_neg_integer(),
          samples: non_neg_integer(),
          extended: boolean(),
          last_fs: boolean() | nil,
          normal_s: float(),
          retro_base: float() | nil,
          baseline_since_ms: integer() | nil,
          pending: [integer()],
          last_engaged: boolean() | nil,
          contradictions: non_neg_integer()
        }

  @doc "A fresh, empty layout state."
  @spec new() :: t()
  def new do
    %{
      baseline: nil,
      baseline_aw: nil,
      mode: "normal",
      run_started_ms: nil,
      run_seconds: 0.0,
      last_at_ms: nil,
      window_s: 0.0,
      viewport_s: 0.0,
      unfocused_s: 0.0,
      unfocused_run_s: 0.0,
      peeks: 0,
      samples: 0,
      extended: false,
      last_fs: nil,
      # Normal-looking seconds under the current baseline, kept so they can
      # be re-judged if the page later turns out to have been narrow all
      # along (see `maybe_retro/2`).
      normal_s: 0.0,
      retro_base: nil,
      baseline_since_ms: nil,
      # Server-observed answer interactions (unix ms) waiting for the next
      # heartbeat's samples, the engaged/not flag of the last sample seen,
      # and how many interactions the samples contradicted.
      pending: [],
      last_engaged: nil,
      contradictions: 0
    }
  end

  @doc """
  Whether a (checkpoint-restored) value has the exact shape of `new/0`.
  A restore that fails this is ignored in favour of a fresh state.
  """
  @spec valid?(term()) :: boolean()
  def valid?(%{} = layout) do
    template = new()

    Enum.sort(Map.keys(layout)) == Enum.sort(Map.keys(template)) and
      layout.mode in @modes and
      Enum.all?(
        [:run_seconds, :window_s, :viewport_s, :unfocused_s, :unfocused_run_s],
        &(is_number(layout[&1]) and layout[&1] >= 0)
      ) and
      Enum.all?(
        [:peeks, :samples, :contradictions],
        &(is_integer(layout[&1]) and layout[&1] >= 0)
      ) and
      is_number(layout.normal_s) and layout.normal_s >= 0 and
      (is_nil(layout.retro_base) or is_number(layout.retro_base)) and
      (is_nil(layout.baseline_since_ms) or is_integer(layout.baseline_since_ms)) and
      is_list(layout.pending) and length(layout.pending) <= @max_pending and
      Enum.all?(layout.pending, &is_integer/1) and
      (is_nil(layout.last_engaged) or is_boolean(layout.last_engaged)) and
      is_boolean(layout.extended) and
      (is_nil(layout.baseline) or is_number(layout.baseline)) and
      (is_nil(layout.baseline_aw) or is_integer(layout.baseline_aw)) and
      (is_nil(layout.run_started_ms) or is_integer(layout.run_started_ms)) and
      (is_nil(layout.last_at_ms) or is_integer(layout.last_at_ms)) and
      (is_nil(layout.last_fs) or is_boolean(layout.last_fs))
  end

  def valid?(_), do: false

  @doc """
  Bounds and types untrusted samples from the client. Anything that is not
  a list of maps yields `[]`; numbers are clamped, flags are `true`/`false`
  or `nil` (unknown).
  """
  @spec sanitize_samples(term()) :: [map()]
  def sanitize_samples(samples) when is_list(samples) do
    samples
    |> Enum.take(@max_samples)
    |> Enum.flat_map(fn
      %{} = raw -> [sanitize_sample(raw)]
      _ -> []
    end)
  end

  def sanitize_samples(_), do: []

  defp sanitize_sample(raw) do
    %{
      ow: dim(fetch(raw, "ow")),
      oh: dim(fetch(raw, "oh")),
      iw: dim(fetch(raw, "iw")),
      ih: dim(fetch(raw, "ih")),
      aw: dim(fetch(raw, "aw")),
      ah: dim(fetch(raw, "ah")),
      dpr: dpr(fetch(raw, "dpr")),
      f: flag(fetch(raw, "f")),
      vis: flag(fetch(raw, "vis")),
      ext: flag(fetch(raw, "ext")),
      fs: flag(fetch(raw, "fs"))
    }
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  end

  defp dim(v) when is_number(v) and v > 0, do: v |> min(@max_dim) |> trunc()
  defp dim(_), do: 0

  defp dpr(v) when is_number(v) and v > 0, do: v |> max(0.25) |> min(16.0) |> Kernel.*(1.0)
  defp dpr(_), do: 1.0

  defp flag(true), do: true
  defp flag(false), do: false
  defp flag(_), do: nil

  @doc """
  The class of one sample: `:normal`, `:window` or `:viewport`.

  `baseline` is the widest viewport-to-window ratio seen so far (see
  `viewport_ratio/1`), `nil` before the first measurement.
  """
  @spec classify(map(), float() | nil) :: :normal | :window | :viewport
  def classify(%{fs: true}, _baseline), do: :normal

  def classify(sample, baseline) do
    t = thresholds()

    cond do
      sample.aw < t.min_screen_width ->
        :normal

      sample.ow > 0 and sample.ow / sample.aw <= t.width_ratio ->
        :window

      sample.ah > 0 and sample.oh > 0 and sample.oh / sample.ah <= t.height_ratio ->
        :window

      narrowed?(sample, baseline, t) ->
        :viewport

      true ->
        :normal
    end
  end

  defp narrowed?(sample, baseline, t) do
    case {viewport_ratio(sample), baseline} do
      {ratio, base} when is_number(ratio) and is_number(base) and base > 0 ->
        ratio / base < t.viewport_ratio

      _ ->
        false
    end
  end

  @doc """
  Page width as a share of window width, in device pixels (inner width times
  DPR over outer width). Browser zoom changes `innerWidth` and the DPR in
  opposite directions, so the product stays put - a narrower value means the
  page area really got narrower. `nil` when the window has no width.
  """
  @spec viewport_ratio(map()) :: float() | nil
  def viewport_ratio(%{ow: ow, iw: iw, dpr: dpr}) when ow > 0 and iw > 0, do: iw * dpr / ow
  def viewport_ratio(_), do: nil

  @doc """
  Folds the samples that arrived with one heartbeat into the layout state.

  Returns `{layout, incidents}`; `incidents` are new, ready-to-store
  incident maps (a finished split interval, a first sighting of an extended
  display). The time a heartbeat covers is the real time since the previous
  one (at most #{@max_delta_s}s), shared equally among its samples.
  """
  @spec ingest(t(), term(), DateTime.t()) :: {t(), [map()]}
  def ingest(layout, raw_samples, %DateTime{} = now) do
    samples = sanitize_samples(raw_samples)
    now_ms = DateTime.to_unix(now, :millisecond)

    case samples do
      [] ->
        {%{layout | last_at_ms: now_ms}, []}

      _ ->
        n = length(samples)

        delta_s =
          case layout.last_at_ms do
            nil -> min(n * @sample_interval_s, @max_delta_s)
            prev -> (now_ms - prev) |> div(1000) |> max(0) |> min(@max_delta_s)
          end

        run_ref_ms = layout.last_at_ms || now_ms - delta_s * 1000
        per = delta_s / n

        {layout, contradictions} = check_interactions(layout, samples, now_ms)

        {layout, incidents} =
          Enum.reduce(samples, {layout, contradictions}, fn sample, {l, inc} ->
            {l, new} = step(l, sample, per, run_ref_ms)
            {l, inc ++ new}
          end)

        {%{layout | last_at_ms: now_ms, pending: [], last_engaged: engaged?(List.last(samples))},
         incidents}
    end
  end

  defp step(layout, sample, per, run_ref_ms) do
    layout = %{layout | samples: layout.samples + 1, last_fs: sample.fs}
    {layout, retro} = update_baseline(layout, sample, run_ref_ms)
    mode = sample |> classify(layout.baseline) |> Atom.to_string()

    {layout, incidents} = switch_mode(layout, mode, run_ref_ms)

    layout =
      layout
      |> account_mode(mode, per)
      |> account_normal(mode, sample, per)
      |> account_focus(sample, per)

    note_extended(layout, sample, retro ++ incidents, run_ref_ms)
  end

  # A changed screen (another monitor, different resolution) invalidates the
  # baseline - the ratio is only comparable on one screen.
  defp update_baseline(layout, %{aw: aw} = sample, run_ref_ms) do
    layout =
      if layout.baseline_aw not in [nil, aw],
        do: %{layout | baseline: nil, retro_base: nil, normal_s: 0.0, baseline_since_ms: nil},
        else: layout

    layout = %{layout | baseline_aw: aw}

    # Fullscreen samples are left out of the baseline: going fullscreen
    # (which an exam may require) widens the page without that meaning the
    # time before it was spent narrowed.
    case if(sample.fs == true, do: nil, else: viewport_ratio(sample)) do
      nil ->
        {layout, []}

      ratio ->
        maybe_retro(%{layout | baseline: max(layout.baseline || 0.0, ratio)}, run_ref_ms)
    end
  end

  # The baseline is the widest page seen, so a page that was narrow from the
  # very first sample looked "normal" to itself. When it later turns out much
  # wider, the time spent under the narrower baseline is re-judged as a
  # narrowed page (same threshold as a live detection) and reported once.
  defp maybe_retro(%{retro_base: nil} = layout, run_ref_ms),
    do: {%{layout | retro_base: layout.baseline, baseline_since_ms: run_ref_ms}, []}

  defp maybe_retro(layout, run_ref_ms) do
    if layout.retro_base / layout.baseline < thresholds().viewport_ratio do
      incidents =
        if layout.normal_s >= @min_interval_s do
          [
            %{
              "type" => "split_interval",
              "cause" => "viewport",
              "at" => iso(layout.baseline_since_ms),
              "seconds" => round(layout.normal_s),
              "retroactive" => true
            }
          ]
        else
          []
        end

      {%{
         layout
         | viewport_s: layout.viewport_s + layout.normal_s,
           normal_s: 0.0,
           retro_base: layout.baseline,
           baseline_since_ms: run_ref_ms
       }, incidents}
    else
      {layout, []}
    end
  end

  defp account_normal(layout, "normal", %{fs: fs}, per) when fs != true,
    do: %{layout | normal_s: layout.normal_s + per}

  defp account_normal(layout, _mode, _sample, _per), do: layout

  defp switch_mode(%{mode: mode} = layout, mode, _run_ref_ms), do: {layout, []}

  defp switch_mode(layout, new_mode, run_ref_ms) do
    incidents =
      case interval_incident(layout) do
        nil -> []
        incident -> [incident]
      end

    {%{layout | mode: new_mode, run_started_ms: run_ref_ms, run_seconds: 0.0}, incidents}
  end

  defp account_mode(layout, "normal", _per), do: layout

  defp account_mode(layout, "window", per),
    do: %{layout | run_seconds: layout.run_seconds + per, window_s: layout.window_s + per}

  defp account_mode(layout, "viewport", per),
    do: %{layout | run_seconds: layout.run_seconds + per, viewport_s: layout.viewport_s + per}

  # "Not looking at the exam": hidden, or visible but without input focus.
  # The open run is tracked separately so a blur still in progress (whose
  # absence the browser only reports on return) is not mistaken for an
  # unreported one.
  defp account_focus(layout, %{vis: vis, f: f}, per) when vis == false or f == false do
    %{
      layout
      | unfocused_s: layout.unfocused_s + per,
        unfocused_run_s: layout.unfocused_run_s + per
    }
  end

  defp account_focus(layout, _sample, _per), do: %{layout | unfocused_run_s: 0.0}

  defp note_extended(%{extended: false} = layout, %{ext: true}, incidents, run_ref_ms) do
    incident = %{
      "type" => "extended_display",
      "at" => iso(run_ref_ms),
      "seconds" => 0
    }

    {%{layout | extended: true}, incidents ++ [incident]}
  end

  defp note_extended(layout, _sample, incidents, _run_ref_ms), do: {layout, incidents}

  @doc """
  Notes an answer interaction the server itself observed (an answer saved, a
  code run) at `at_ms`. It is checked against the focus samples of the next
  heartbeat: nobody can answer in a page that was neither visible nor
  focused before, around and after the moment, so such an interaction means
  the samples are false or the answer did not come from the page's UI.
  """
  @spec note_interaction(t(), integer()) :: t()
  def note_interaction(layout, at_ms) when is_integer(at_ms),
    do: %{layout | pending: Enum.take([at_ms | layout.pending], @max_pending)}

  # Judges pending interactions against the samples that bracket them: the
  # sample before (the previous heartbeat's last one for the first slot), the
  # one at the interaction and the one after. Only when none of them shows
  # the page engaged is it a contradiction. Interactions older than the
  # previous heartbeat have no samples to be judged by and are skipped.
  defp check_interactions(%{pending: []} = layout, _samples, _now_ms), do: {layout, []}
  defp check_interactions(%{last_at_ms: nil} = layout, _samples, _now_ms), do: {layout, []}

  defp check_interactions(layout, samples, now_ms) do
    flags = Enum.map(samples, &engaged?/1)
    count = length(flags)
    prev = layout.last_at_ms

    hits =
      layout.pending
      |> Enum.filter(&(&1 >= prev and &1 <= now_ms))
      |> Enum.filter(fn at_ms ->
        index = (at_ms - prev) |> div(@sample_ms) |> min(count - 1)
        around = for k <- (index - 1)..(index + 1)//1, k >= 0 and k < count, do: Enum.at(flags, k)
        around = if index - 1 < 0, do: [layout.last_engaged != false | around], else: around
        around != [] and Enum.all?(around, &(&1 == false))
      end)

    new_total = layout.contradictions + length(hits)
    room = max(@max_contradiction_incidents - layout.contradictions, 0)

    incidents =
      hits
      |> Enum.sort()
      |> Enum.take(room)
      |> Enum.map(&%{"type" => "answer_while_unfocused", "at" => iso(&1), "seconds" => 0})

    {%{layout | contradictions: new_total}, incidents}
  end

  defp engaged?(%{vis: vis, f: f}), do: not (vis == false or f == false)

  @doc """
  Records the pointer leaving the window sideways while the window shares
  the screen - the pointer going to the neighbouring window. Top/bottom
  exits are ignored (they are the tab bar and the OS bar).
  """
  @spec note_mouse_exit(t(), term()) :: t()
  def note_mouse_exit(%{mode: mode} = layout, edge)
      when mode != "normal" and edge in ["left", "right"],
      do: %{layout | peeks: layout.peeks + 1}

  def note_mouse_exit(layout, _edge), do: layout

  @doc "Totals for the monitor's reading. The open unfocused run is excluded."
  @spec summary(t()) :: map()
  def summary(layout) do
    %{
      layout_samples: layout.samples,
      split_seconds: round(layout.window_s),
      viewport_split_seconds: round(layout.viewport_s),
      unfocused_seconds: round(max(layout.unfocused_s - layout.unfocused_run_s, 0.0)),
      split_peeks: layout.peeks,
      extended_display: layout.extended,
      answer_contradictions: layout.contradictions,
      layout_fullscreen: layout.last_fs
    }
  end

  @doc "The still-open split interval as an incident, if long enough to matter."
  @spec open_incident(t()) :: map() | nil
  def open_incident(layout), do: interval_incident(layout)

  defp interval_incident(%{mode: "normal"}), do: nil

  defp interval_incident(%{run_seconds: seconds} = layout) when seconds >= @min_interval_s do
    %{
      "type" => "split_interval",
      "cause" => layout.mode,
      "at" => iso(layout.run_started_ms),
      "seconds" => round(seconds)
    }
  end

  defp interval_incident(_), do: nil

  defp iso(nil), do: DateTime.to_iso8601(DateTime.utc_now())

  defp iso(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end

  @doc "Tunable thresholds (config under `Athena.Engagement`)."
  @spec thresholds() :: map()
  def thresholds do
    config = Application.get_env(:athena, Athena.Engagement, [])

    %{
      width_ratio: Keyword.get(config, :exam_split_width_ratio, 0.70),
      height_ratio: Keyword.get(config, :exam_split_height_ratio, 0.60),
      viewport_ratio: Keyword.get(config, :exam_viewport_shrink_ratio, 0.80),
      min_screen_width: Keyword.get(config, :exam_split_min_screen_width, 1000)
    }
  end
end
