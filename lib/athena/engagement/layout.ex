defmodule Athena.Engagement.Layout do
  @moduledoc """
  Best-effort layout observations for instructor review, never proof of cheating.
  Millisecond intervals are bounded by server monotonic receipt times. The
  first batch and gaps without coverage establish a baseline without charging
  time. Browser geometry/focus remain client-reported. Past time is never
  reclassified after a wider viewport or a different screen is seen.
  """

  @max_samples 10
  @max_dim 20_000
  @max_delta_s 30
  @stable_seconds 3
  @max_pending 20
  @max_contradiction_incidents 3
  @min_interval_s 5

  @modes ["normal", "window", "viewport"]

  @type t :: %{
          baseline: float() | nil,
          baseline_aw: non_neg_integer() | nil,
          baseline_ah: non_neg_integer() | nil,
          baseline_dpr: number() | nil,
          last_mono_ms: integer() | nil,
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
      baseline_ah: nil,
      baseline_dpr: nil,
      last_mono_ms: nil,
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
      # Legacy checkpoint fields retained for compatibility; normal-looking
      # time is never reclassified retrospectively.
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

    required = Map.keys(template) -- [:baseline_ah, :baseline_dpr, :last_mono_ms]

    shape? =
      Enum.all?(required, &Map.has_key?(layout, &1)) and
        Enum.all?(Map.keys(layout), &Map.has_key?(template, &1))

    shape? and valid_fields?(Map.merge(template, layout))
  end

  def valid?(_), do: false

  defp valid_fields?(layout) do
    groups = [
      {[:run_seconds, :window_s, :viewport_s, :unfocused_s, :unfocused_run_s, :normal_s],
       &non_negative_number?/1},
      {[:peeks, :samples, :contradictions], &non_negative_integer?/1},
      {[
         :baseline_ah,
         :last_mono_ms,
         :baseline_since_ms,
         :baseline_aw,
         :run_started_ms,
         :last_at_ms
       ], &optional_integer?/1},
      {[:baseline_dpr, :retro_base, :baseline], &optional_number?/1},
      {[:last_engaged, :last_fs], &optional_boolean?/1},
      {[:extended], &is_boolean/1}
    ]

    layout.mode in @modes and valid_pending?(layout.pending) and
      Enum.all?(groups, fn {fields, validator} ->
        Enum.all?(fields, &validator.(Map.fetch!(layout, &1)))
      end)
  end

  defp non_negative_number?(value), do: is_number(value) and value >= 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp optional_integer?(value), do: is_nil(value) or is_integer(value)
  defp optional_number?(value), do: is_nil(value) or is_number(value)
  defp optional_boolean?(value), do: is_nil(value) or is_boolean(value)

  defp valid_pending?(pending) when is_list(pending),
    do: length(pending) <= @max_pending and Enum.all?(pending, &is_integer/1)

  defp valid_pending?(_), do: false

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
  Receives one bounded batch. With no previous receipt there is no elapsed
  time to charge. Production callers supply a monotonic clock; tests may use
  their explicit server timestamps. Missing or delayed batches break coverage.
  """
  def ingest(layout, raw_samples, %DateTime{} = now, monotonic_ms \\ nil) do
    layout = Map.merge(new(), layout)
    samples = sanitize_samples(raw_samples)
    now_ms = DateTime.to_unix(now, :millisecond)
    clock_ms = monotonic_ms || now_ms
    previous_clock = layout.last_mono_ms
    delta_ms = if is_integer(previous_clock), do: max(clock_ms - previous_clock, 0), else: 0
    covered? = is_integer(previous_clock) and delta_ms <= @max_delta_s * 1000

    {layout, closed} = prepare_coverage(layout, samples, covered?, now_ms)

    case samples do
      [] ->
        {%{layout | last_at_ms: nil, last_mono_ms: nil, pending: []}, closed}

      _ ->
        elapsed_ms = if covered?, do: delta_ms, else: 0
        per = elapsed_ms / length(samples) / 1000
        start_ms = now_ms - elapsed_ms
        {layout, observations} = check_interactions(layout, samples, now_ms)

        {layout, incidents} =
          samples
          |> Enum.with_index()
          |> Enum.reduce({layout, closed ++ observations}, fn {sample, index}, {l, acc} ->
            at_ms = start_ms + round(index * per * 1000)
            {l, added} = step(l, sample, per, at_ms)
            {l, acc ++ added}
          end)

        {%{
           layout
           | last_at_ms: now_ms,
             last_mono_ms: clock_ms,
             pending: [],
             last_engaged: engaged?(List.last(samples))
         }, incidents}
    end
  end

  defp prepare_coverage(layout, samples, covered?, now_ms) do
    if samples == [] or not covered? do
      {fresh, incidents} = switch_mode(layout, "normal", layout.last_at_ms || now_ms)

      {%{
         fresh
         | unfocused_s: max(fresh.unfocused_s - fresh.unfocused_run_s, 0),
           unfocused_run_s: 0.0,
           last_engaged: nil,
           pending: []
       }, incidents}
    else
      {layout, []}
    end
  end

  @doc "Restores totals while discarding transient layout/focus and downtime."
  def resume(saved) do
    if valid?(saved) do
      saved = Map.merge(new(), saved)

      %{
        saved
        | last_at_ms: nil,
          last_mono_ms: nil,
          mode: "normal",
          run_seconds: 0.0,
          run_started_ms: nil,
          baseline: nil,
          baseline_aw: nil,
          baseline_ah: nil,
          baseline_dpr: nil,
          retro_base: nil,
          normal_s: 0.0,
          baseline_since_ms: nil,
          unfocused_s: max(saved.unfocused_s - saved.unfocused_run_s, 0),
          unfocused_run_s: 0.0,
          last_engaged: nil,
          pending: []
      }
    else
      new()
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
      |> account_focus(sample, per)

    note_extended(layout, sample, retro ++ incidents, run_ref_ms)
  end

  # A changed display scale or resolution invalidates the viewport baseline.
  # Reset conservatively on DPR changes too: zoom must not create a violation.
  defp update_baseline(layout, sample, _at_ms) do
    changed? =
      layout.baseline_aw not in [nil, sample.aw] or
        layout.baseline_ah not in [nil, sample.ah] or
        layout.baseline_dpr not in [nil, sample.dpr]

    baseline = if changed?, do: nil, else: layout.baseline
    ratio = if sample.fs == true, do: nil, else: viewport_ratio(sample)
    baseline = if is_number(ratio), do: max(baseline || 0.0, ratio), else: baseline

    {%{
       layout
       | baseline: baseline,
         baseline_aw: sample.aw,
         baseline_ah: sample.ah,
         baseline_dpr: sample.dpr,
         normal_s: 0.0,
         retro_base: nil,
         baseline_since_ms: nil
     }, []}
  end

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

  defp account_mode(layout, mode, per) do
    total = layout.run_seconds + per

    credited =
      cond do
        total < @stable_seconds -> 0.0
        layout.run_seconds < @stable_seconds -> total
        true -> per
      end

    key = if mode == "window", do: :window_s, else: :viewport_s
    layout |> Map.put(:run_seconds, total) |> Map.update!(key, &(&1 + credited))
  end

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
  Notes receipt of an answer save or code run. Surrounding focus samples
  provide context only: brief focus changes and delayed autosaves are normal.
  These observations never earn risk points.
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
      |> Enum.filter(fn at_ms ->
        at_ms >= prev and at_ms <= now_ms and
          unfocused_near?(layout, flags, count, prev, now_ms, at_ms)
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

  defp unfocused_near?(layout, flags, count, prev, now_ms, at_ms) do
    index = min(div((at_ms - prev) * count, max(now_ms - prev, 1)), count - 1)
    around = for k <- (index - 1)..(index + 1)//1, k >= 0 and k < count, do: Enum.at(flags, k)
    around = if index - 1 < 0, do: [layout.last_engaged != false | around], else: around
    around != [] and Enum.all?(around, &(&1 == false))
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
