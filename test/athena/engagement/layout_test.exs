defmodule Athena.Engagement.LayoutTest do
  use ExUnit.Case, async: true
  alias Athena.Engagement.Layout

  @t0 ~U[2026-11-17 10:00:00Z]
  defp sample(overrides \\ %{}) do
    Map.merge(
      %{
        "ow" => 1920,
        "oh" => 1040,
        "iw" => 1905,
        "ih" => 950,
        "aw" => 1920,
        "ah" => 1040,
        "dpr" => 1.0,
        "f" => true,
        "vis" => true,
        "ext" => false,
        "fs" => false
      },
      overrides
    )
  end

  defp half, do: sample(%{"ow" => 960, "iw" => 945})
  defp at(ms), do: DateTime.add(@t0, ms, :millisecond)
  defp ingest(l, samples, ms), do: Layout.ingest(l, samples, at(ms))

  test "normalization bounds hostile samples and tolerates missing APIs" do
    assert Layout.sanitize_samples(nil) == []
    assert Layout.sanitize_samples([1, nil, "x"]) == []
    assert length(Layout.sanitize_samples(List.duplicate(sample(), 100))) == 10

    [s] =
      Layout.sanitize_samples([sample(%{"ow" => Integer.pow(10, 400), "iw" => -1, "f" => "yes"})])

    assert s.ow == 20_000
    assert s.iw == 0
    assert s.f == nil
  end

  test "classification distinguishes window sharing and a narrowed viewport" do
    [full, narrow, h] = Layout.sanitize_samples([sample(), sample(%{"iw" => 950}), half()])
    assert Layout.classify(full, nil) == :normal
    assert Layout.classify(h, nil) == :window
    assert Layout.classify(narrow, Layout.viewport_ratio(full)) == :viewport
    [vertical] = Layout.sanitize_samples([sample(%{"oh" => 500})])
    assert Layout.classify(vertical, nil) == :window
    [fullscreen] = Layout.sanitize_samples([Map.put(half(), "fs", true)])
    assert Layout.classify(fullscreen, nil) == :normal
    [small] = Layout.sanitize_samples([sample(%{"aw" => 800, "ow" => 300})])
    assert Layout.classify(small, nil) == :normal
  end

  test "the first heartbeat cannot invent time, regardless of sample count" do
    {layout, []} = ingest(Layout.new(), List.duplicate(half(), 10), 0)
    assert Layout.summary(layout).split_seconds == 0
    assert Layout.open_incident(layout) == nil
    assert Layout.summary(layout).layout_samples == 10
  end

  test "frequent heartbeats retain fractional seconds rather than rounding them away" do
    {layout, _} = ingest(Layout.new(), [half()], 0)

    {layout, _} =
      Enum.reduce(1..20, {layout, []}, fn i, {l, _} -> ingest(l, [half()], i * 500) end)

    assert Layout.summary(layout).split_seconds == 10
  end

  test "production intervals use the monotonic clock even when the wall clock jumps" do
    {layout, _} = Layout.ingest(Layout.new(), [half()], @t0, 1000)
    {layout, _} = Layout.ingest(layout, [half()], at(3_600_000), 11_000)
    assert Layout.summary(layout).split_seconds == 10
  end

  test "each sample's interval starts at its own position within a batch" do
    {layout, _} = ingest(Layout.new(), [sample()], 0)
    {layout, _} = ingest(layout, [sample(), sample(), half(), half(), half()], 10_000)
    assert %{"at" => "2026-11-17T10:00:04.000Z", "seconds" => 6} = Layout.open_incident(layout)
    {_, incidents} = ingest(layout, [sample()], 12_000)
    assert [%{"at" => "2026-11-17T10:00:04.000Z", "seconds" => 6}] = incidents
  end

  test "short resize jitter is not accumulated as split time" do
    {layout, _} = ingest(Layout.new(), [sample()], 0)
    {layout, _} = ingest(layout, [half()], 1000)
    {layout, incidents} = ingest(layout, [sample()], 2000)
    assert Layout.summary(layout).split_seconds == 0
    assert incidents == []
  end

  test "long pauses break coverage instead of attributing missing time to a layout" do
    {layout, _} = ingest(Layout.new(), [half()], 0)
    {layout, _} = ingest(layout, [half()], 10_000)
    {layout, incidents} = ingest(layout, [half()], 3_600_000)
    assert Layout.summary(layout).split_seconds == 10
    assert [%{"seconds" => 10}] = incidents
    assert Layout.open_incident(layout) == nil
  end

  test "missing samples break coverage and do not let the next sample fill the gap" do
    {layout, _} = ingest(Layout.new(), [sample()], 0)
    {layout, _} = ingest(layout, [], 10_000)
    {layout, _} = ingest(layout, [half()], 20_000)
    assert Layout.summary(layout).split_seconds == 0
  end

  test "a later wider viewport never retroactively labels earlier time as split" do
    narrow = sample(%{"iw" => 950})
    {layout, _} = ingest(Layout.new(), [narrow], 0)
    {layout, _} = ingest(layout, [narrow], 10_000)
    {layout, incidents} = ingest(layout, [sample()], 20_000)
    assert Layout.summary(layout).viewport_split_seconds == 0
    assert incidents == []
  end

  test "normal zoom and display-scale changes reset the viewport baseline" do
    {layout, _} = ingest(Layout.new(), [sample()], 0)
    zoom = sample(%{"iw" => 1270, "dpr" => 1.5})
    {layout, _} = ingest(layout, [zoom], 10_000)
    {layout, _} = ingest(layout, [sample()], 20_000)
    assert Layout.summary(layout).viewport_split_seconds == 0
    other = sample(%{"aw" => 2560, "ow" => 2560, "iw" => 1280})
    {layout, _} = ingest(layout, [other], 30_000)
    assert Layout.summary(layout).viewport_split_seconds == 0
  end

  test "a sustained viewport reduction is measured without counting it as a window" do
    {layout, _} = ingest(Layout.new(), [sample()], 0)
    {layout, _} = ingest(layout, [sample(%{"iw" => 950})], 10_000)
    assert Layout.summary(layout).viewport_split_seconds == 10
    assert Layout.summary(layout).split_seconds == 0
  end

  test "a second display is reported once without inventing an interval" do
    {layout, [incident]} = ingest(Layout.new(), [sample(%{"ext" => true})], 0)
    {layout, []} = ingest(layout, [sample(%{"ext" => true})], 10_000)
    assert incident["type"] == "extended_display"
    assert {:ok, observed_at, 0} = DateTime.from_iso8601(incident["at"])
    assert DateTime.compare(observed_at, @t0) == :eq
    assert Layout.summary(layout).extended_display
  end

  test "open focus loss is excluded until a later sample reports focus" do
    unfocused = sample(%{"f" => false})
    {layout, _} = ingest(Layout.new(), [unfocused], 0)
    {layout, _} = ingest(layout, [unfocused], 10_000)
    assert Layout.summary(layout).unfocused_seconds == 0
    {layout, _} = ingest(layout, [sample()], 12_000)
    assert Layout.summary(layout).unfocused_seconds == 10
  end

  test "focus observations are approximate and retain surrounding engaged samples" do
    unfocused = sample(%{"f" => false})
    {layout, _} = ingest(Layout.new(), [unfocused], 0)
    layout = Layout.note_interaction(layout, DateTime.to_unix(at(3000), :millisecond))

    {layout, incidents} =
      ingest(layout, [unfocused, sample(), unfocused, unfocused, unfocused], 10_000)

    assert Layout.summary(layout).answer_contradictions == 0
    assert incidents == []
  end

  test "an all-unfocused batch records context without declaring a violation" do
    unfocused = sample(%{"f" => false})
    {layout, _} = ingest(Layout.new(), [unfocused], 0)
    layout = Layout.note_interaction(layout, DateTime.to_unix(at(3000), :millisecond))

    {layout, [%{"type" => "answer_while_unfocused"}]} =
      ingest(layout, List.duplicate(unfocused, 5), 10_000)

    assert Layout.summary(layout).answer_contradictions == 1
  end

  test "resume preserves totals without promoting unfinished focus loss or downtime" do
    unfocused = Map.put(half(), "f", false)
    {layout, _} = ingest(Layout.new(), [unfocused], 0)
    {layout, _} = ingest(layout, [unfocused], 10_000)
    resumed = Layout.resume(layout)
    assert Layout.summary(resumed).split_seconds == 10
    assert Layout.summary(resumed).unfocused_seconds == 0
    assert resumed.pending == []
    assert resumed.baseline == nil
    {resumed, _} = ingest(resumed, [unfocused], 3_600_000)
    assert Layout.summary(resumed).split_seconds == 10
  end

  test "old checkpoints are accepted, malformed checkpoints are rejected" do
    old = Map.drop(Layout.new(), [:baseline_ah, :baseline_dpr, :last_mono_ms])
    assert Layout.valid?(old)
    assert Layout.valid?(Layout.resume(old))
    refute Layout.valid?(%{})
    refute Layout.valid?(nil)
    refute Layout.valid?(Map.put(Layout.new(), :extra, 1))
    refute Layout.valid?(%{Layout.new() | window_s: -1})
    assert Layout.resume(%{}) == Layout.new()
  end

  test "pointer exits are contextual and only sideways exits are counted" do
    {layout, _} = ingest(Layout.new(), [half()], 0)

    layout =
      layout
      |> Layout.note_mouse_exit("left")
      |> Layout.note_mouse_exit("right")
      |> Layout.note_mouse_exit("top")

    assert Layout.summary(layout).split_peeks == 2
    assert Layout.summary(Layout.note_mouse_exit(Layout.new(), "left")).split_peeks == 0
  end
end
