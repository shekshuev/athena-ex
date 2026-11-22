defmodule Athena.Engagement.LayoutTest do
  use ExUnit.Case, async: true

  alias Athena.Engagement.Layout

  # A maximized 1920x1080 window, focused and visible.
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

  defp half_window, do: sample(%{"ow" => 960, "iw" => 945})

  defp ingest(layout, samples, at), do: Layout.ingest(layout, samples, at)

  @t0 ~U[2026-11-17 10:00:00Z]

  describe "sanitize_samples/1" do
    test "drops anything that is not a list of maps" do
      assert Layout.sanitize_samples(nil) == []
      assert Layout.sanitize_samples("x") == []
      assert Layout.sanitize_samples([1, "a", nil]) == []
    end

    test "keeps at most ten samples" do
      assert length(Layout.sanitize_samples(List.duplicate(sample(), 40))) == 10
    end

    test "clamps absurd numbers and turns unknown flags into nil" do
      [s] = Layout.sanitize_samples([sample(%{"ow" => 1.0e12, "iw" => -5, "f" => "yes"})])

      assert s.ow == 20_000
      assert s.iw == 0
      assert s.f == nil
    end
  end

  describe "classify/2" do
    test "a maximized window is normal" do
      [s] = Layout.sanitize_samples([sample()])
      assert Layout.classify(s, Layout.viewport_ratio(s)) == :normal
    end

    test "a half-width window is a window split" do
      [s] = Layout.sanitize_samples([half_window()])
      assert Layout.classify(s, nil) == :window
    end

    test "a half-height window is a window split" do
      [s] = Layout.sanitize_samples([sample(%{"oh" => 500, "ih" => 420})])
      assert Layout.classify(s, nil) == :window
    end

    test "fullscreen is never a split" do
      [s] = Layout.sanitize_samples([Map.put(half_window(), "fs", true)])
      assert Layout.classify(s, nil) == :normal
    end

    test "small screens are ignored" do
      [s] = Layout.sanitize_samples([sample(%{"aw" => 800, "ow" => 300, "iw" => 290})])
      assert Layout.classify(s, nil) == :normal
    end

    test "a narrowed page in a full-size window is a viewport split" do
      [full] = Layout.sanitize_samples([sample()])
      [narrow] = Layout.sanitize_samples([sample(%{"iw" => 950})])

      assert Layout.classify(narrow, Layout.viewport_ratio(full)) == :viewport
    end

    test "browser zoom does not look like a narrowed page" do
      [full] = Layout.sanitize_samples([sample()])
      # 150% zoom: fewer CSS pixels, proportionally more device pixels each.
      [zoomed] = Layout.sanitize_samples([sample(%{"iw" => 1270, "dpr" => 1.5})])

      assert Layout.classify(zoomed, Layout.viewport_ratio(full)) == :normal
    end
  end

  describe "ingest/3 - time is measured by the server" do
    test "the first heartbeat covers two seconds per sample" do
      {layout, _} = ingest(Layout.new(), List.duplicate(half_window(), 5), @t0)

      assert Layout.summary(layout).split_seconds == 10
    end

    test "later heartbeats cover the real time since the previous one" do
      {layout, _} = ingest(Layout.new(), [sample()], @t0)
      {layout, _} = ingest(layout, List.duplicate(half_window(), 5), DateTime.add(@t0, 10))

      assert Layout.summary(layout).split_seconds == 10
    end

    test "a client cannot inflate time by sending many samples in a short ping" do
      {layout, _} = ingest(Layout.new(), [sample()], @t0)
      {layout, _} = ingest(layout, List.duplicate(half_window(), 10), DateTime.add(@t0, 1))

      assert Layout.summary(layout).split_seconds == 1
    end

    test "a long pause between pings is capped" do
      {layout, _} = ingest(Layout.new(), [sample()], @t0)
      {layout, _} = ingest(layout, [half_window()], DateTime.add(@t0, 3_600))

      assert Layout.summary(layout).split_seconds == 30
    end

    test "a ping without samples adds nothing" do
      {layout, incidents} = ingest(Layout.new(), [], @t0)

      assert incidents == []
      assert Layout.summary(layout).layout_samples == 0
    end

    test "a narrowed page counts as viewport time, not window time" do
      {layout, _} = ingest(Layout.new(), [sample()], @t0)
      narrow = sample(%{"iw" => 950})
      {layout, _} = ingest(layout, List.duplicate(narrow, 5), DateTime.add(@t0, 10))

      summary = Layout.summary(layout)
      assert summary.viewport_split_seconds == 10
      assert summary.split_seconds == 0
    end

    test "a changed screen resets the viewport baseline" do
      {layout, _} = ingest(Layout.new(), [sample()], @t0)
      other_screen = sample(%{"aw" => 2560, "ow" => 2560, "iw" => 1280})
      {layout, _} = ingest(layout, [other_screen], DateTime.add(@t0, 2))

      assert Layout.summary(layout).viewport_split_seconds == 0
    end
  end

  describe "ingest/3 - intervals" do
    test "a finished split becomes a split_interval incident" do
      {layout, []} = ingest(Layout.new(), List.duplicate(half_window(), 5), @t0)
      {layout, incidents} = ingest(layout, [sample()], DateTime.add(@t0, 10))

      assert [%{"type" => "split_interval", "cause" => "window", "seconds" => 10}] = incidents
      assert layout.mode == "normal"
    end

    test "a split that is still going on is available as an open incident" do
      {layout, _} = ingest(Layout.new(), List.duplicate(half_window(), 5), @t0)

      assert %{"type" => "split_interval", "cause" => "window"} = Layout.open_incident(layout)
    end

    test "a blink of a split is not worth an incident" do
      {layout, _} = ingest(Layout.new(), [half_window()], @t0)
      {_layout, incidents} = ingest(layout, [sample()], DateTime.add(@t0, 2))

      assert incidents == []
    end

    test "an extended display is noted once" do
      {layout, [incident]} = ingest(Layout.new(), [sample(%{"ext" => true})], @t0)
      {_layout, again} = ingest(layout, [sample(%{"ext" => true})], DateTime.add(@t0, 2))

      assert incident["type"] == "extended_display"
      assert again == []
    end
  end

  describe "a page that was narrow from the start" do
    defp narrow, do: sample(%{"iw" => 950})

    test "time under the narrow baseline is re-judged once the page turns out wider" do
      {layout, _} = ingest(Layout.new(), List.duplicate(narrow(), 5), @t0)
      assert Layout.summary(layout).viewport_split_seconds == 0

      {layout, incidents} = ingest(layout, [sample()], DateTime.add(@t0, 2))

      assert Layout.summary(layout).viewport_split_seconds == 10

      assert [%{"type" => "split_interval", "cause" => "viewport", "seconds" => 10}] =
               incidents

      assert hd(incidents)["retroactive"] == true
    end

    test "is reported once, not again on every later sample" do
      {layout, _} = ingest(Layout.new(), List.duplicate(narrow(), 5), @t0)
      {layout, _} = ingest(layout, [sample()], DateTime.add(@t0, 2))
      {layout, incidents} = ingest(layout, [sample()], DateTime.add(@t0, 4))

      assert incidents == []
      assert Layout.summary(layout).viewport_split_seconds == 10
    end

    test "going fullscreen does not re-judge the time before it" do
      {layout, _} = ingest(Layout.new(), List.duplicate(narrow(), 5), @t0)
      fullscreen = sample(%{"fs" => true, "iw" => 1920})
      {layout, incidents} = ingest(layout, [fullscreen], DateTime.add(@t0, 2))

      assert incidents == []
      assert Layout.summary(layout).viewport_split_seconds == 0
    end

    test "a small widening is not a retroactive split" do
      {layout, _} = ingest(Layout.new(), List.duplicate(sample(%{"iw" => 1700}), 5), @t0)
      {layout, incidents} = ingest(layout, [sample()], DateTime.add(@t0, 2))

      assert incidents == []
      assert Layout.summary(layout).viewport_split_seconds == 0
    end
  end

  describe "answers against focus samples" do
    defp unfocused, do: sample(%{"f" => false})

    # Heartbeat at @t0, an answer 3s later, heartbeat at +10s.
    defp answered(first, second) do
      {layout, _} = ingest(Layout.new(), first, @t0)
      layout = Layout.note_interaction(layout, DateTime.to_unix(@t0, :millisecond) + 3_000)
      ingest(layout, second, DateTime.add(@t0, 10))
    end

    test "an answer while the samples around it show an unfocused page is a contradiction" do
      {layout, [incident]} = answered([unfocused()], List.duplicate(unfocused(), 5))

      assert Layout.summary(layout).answer_contradictions == 1
      assert incident["type"] == "answer_while_unfocused"
    end

    test "a hidden page counts the same as an unfocused one" do
      hidden = sample(%{"vis" => false})
      {layout, _} = answered([hidden], List.duplicate(hidden, 5))

      assert Layout.summary(layout).answer_contradictions == 1
    end

    test "one engaged sample around the answer is enough to clear it" do
      second = [unfocused(), unfocused(), sample(), unfocused(), unfocused()]
      {layout, incidents} = answered([unfocused()], second)

      assert Layout.summary(layout).answer_contradictions == 0
      assert incidents == []
    end

    test "an engaged page before the answer clears an answer in the first slot" do
      {layout, layout_incidents} = ingest(Layout.new(), [sample()], @t0)
      assert layout_incidents == []

      layout = Layout.note_interaction(layout, DateTime.to_unix(@t0, :millisecond) + 500)
      {layout, _} = ingest(layout, List.duplicate(unfocused(), 5), DateTime.add(@t0, 10))

      assert Layout.summary(layout).answer_contradictions == 0
    end

    test "an answer older than the previous heartbeat has no samples to be judged by" do
      {layout, _} = ingest(Layout.new(), [unfocused()], @t0)
      layout = Layout.note_interaction(layout, DateTime.to_unix(@t0, :millisecond) - 5_000)
      {layout, _} = ingest(layout, List.duplicate(unfocused(), 5), DateTime.add(@t0, 10))

      assert Layout.summary(layout).answer_contradictions == 0
    end

    test "only the first few are written as incidents, all are counted" do
      {layout, _} = ingest(Layout.new(), [unfocused()], @t0)
      base = DateTime.to_unix(@t0, :millisecond)

      layout =
        Enum.reduce(1..6, layout, fn i, l -> Layout.note_interaction(l, base + i * 1_000) end)

      {layout, incidents} = ingest(layout, List.duplicate(unfocused(), 5), DateTime.add(@t0, 10))

      assert Layout.summary(layout).answer_contradictions == 6
      assert length(incidents) == 3
    end
  end

  describe "focus time" do
    test "time still out of focus is not counted until the focus is back" do
      {layout, _} = ingest(Layout.new(), List.duplicate(sample(%{"f" => false}), 5), @t0)
      assert Layout.summary(layout).unfocused_seconds == 0

      {layout, _} = ingest(layout, [sample()], DateTime.add(@t0, 2))
      assert Layout.summary(layout).unfocused_seconds == 10
    end

    test "a hidden page counts as out of focus" do
      {layout, _} = ingest(Layout.new(), List.duplicate(sample(%{"vis" => false}), 5), @t0)
      {layout, _} = ingest(layout, [sample()], DateTime.add(@t0, 2))

      assert Layout.summary(layout).unfocused_seconds == 10
    end
  end

  describe "note_mouse_exit/2" do
    test "counts sideways exits while the window shares the screen" do
      {layout, _} = ingest(Layout.new(), [half_window()], @t0)

      layout = layout |> Layout.note_mouse_exit("left") |> Layout.note_mouse_exit("right")
      assert Layout.summary(layout).split_peeks == 2
    end

    test "ignores top and bottom exits and exits in a normal layout" do
      {split, _} = ingest(Layout.new(), [half_window()], @t0)
      assert Layout.summary(Layout.note_mouse_exit(split, "top")).split_peeks == 0

      {normal, _} = ingest(Layout.new(), [sample()], @t0)
      assert Layout.summary(Layout.note_mouse_exit(normal, "left")).split_peeks == 0
    end
  end

  describe "valid?/1" do
    test "accepts a layout and rejects tampered shapes" do
      assert Layout.valid?(Layout.new())
      refute Layout.valid?(%{})
      refute Layout.valid?(nil)
      refute Layout.valid?(%{Layout.new() | mode: "elsewhere"})
      refute Layout.valid?(%{Layout.new() | window_s: -1.0})
      refute Layout.valid?(Map.put(Layout.new(), :extra, 1))
    end
  end
end
