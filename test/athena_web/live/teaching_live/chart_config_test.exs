defmodule AthenaWeb.TeachingLive.ChartConfigTest do
  use ExUnit.Case, async: true

  alias AthenaWeb.TeachingLive.ChartConfig

  describe "scatter_config/2" do
    test "one Chart.js data point per input point, coordinates and label preserved" do
      points = [
        %{x: 1, y: 2, label: "ivanov"},
        %{x: 3, y: 0, label: "petrov"}
      ]

      config = ChartConfig.scatter_config(points)

      assert config.type == "scatter"
      assert [%{data: data}] = config.data.datasets
      assert data == [%{x: 1, y: 2, label: "ivanov"}, %{x: 3, y: 0, label: "petrov"}]
    end

    test "an empty point list produces an empty (not crashing) dataset" do
      config = ChartConfig.scatter_config([])

      assert [%{data: []}] = config.data.datasets
    end

    test "opts override the dataset label, color, and axis titles" do
      config =
        ChartConfig.scatter_config([],
          dataset_label: "Cohort A",
          color: "#00ff00",
          x_label: "Slacking",
          y_label: "Struggling"
        )

      assert [%{label: "Cohort A", backgroundColor: "#00ff00"}] = config.data.datasets
      assert config.options.scales.x.title.text == "Slacking"
      assert config.options.scales.y.title.text == "Struggling"
    end

    test "defaults are sane when no opts are given" do
      config = ChartConfig.scatter_config([])

      assert [%{label: "Students", backgroundColor: "#ef4444"}] = config.data.datasets
      assert config.options.scales.x.title.text == "X"
      assert config.options.scales.y.title.text == "Y"
    end

    test "the resulting map is JSON-encodable end to end" do
      config = ChartConfig.scatter_config([%{x: 1, y: 1, label: "a"}])

      assert {:ok, json} = Jason.encode(config)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["type"] == "scatter"
    end
  end

  describe "radar_config/2" do
    test "one dataset per series, values in the same order as the given axes" do
      axes = [:fast_dwell, :heavy_paste, :backtracked]

      series = [
        %{label: "Control", values: %{fast_dwell: 0.1, heavy_paste: 0.2, backtracked: 0.3}},
        %{label: "Nudged", values: %{fast_dwell: 0.4, heavy_paste: 0.5, backtracked: 0.6}}
      ]

      config = ChartConfig.radar_config(axes, series)

      assert config.type == "radar"
      assert config.data.labels == ["fast dwell", "heavy paste", "backtracked"]
      assert [control, nudged] = config.data.datasets
      assert control.label == "Control"
      assert control.data == [0.1, 0.2, 0.3]
      assert nudged.label == "Nudged"
      assert nudged.data == [0.4, 0.5, 0.6]
    end

    test "an axis missing from a series' values plots as 0.0, not a crash" do
      config =
        ChartConfig.radar_config([:fast_dwell, :panic_debugging], [
          %{label: "A", values: %{fast_dwell: 0.5}}
        ])

      assert [%{data: data}] = config.data.datasets
      assert data == [0.5, 0.0]
    end

    test "series get distinct colors from the default palette when none is given" do
      series = [%{label: "A", values: %{}}, %{label: "B", values: %{}}]

      config = ChartConfig.radar_config([:fast_dwell], series)

      assert [a, b] = config.data.datasets
      assert a.borderColor != b.borderColor
    end

    test "an explicit color is respected and used to derive a translucent fill" do
      config =
        ChartConfig.radar_config([:fast_dwell], [%{label: "A", values: %{}, color: "#123456"}])

      assert [%{borderColor: "#123456", backgroundColor: "#12345633"}] = config.data.datasets
    end

    test "no series at all still produces a valid, JSON-encodable config" do
      config = ChartConfig.radar_config([:fast_dwell, :heavy_paste], [])

      assert config.data.datasets == []
      assert {:ok, _json} = Jason.encode(config)
    end
  end

  describe "stacked_bar_config/2" do
    test "two stacked datasets (slacking, struggling), one value per section in order" do
      rows = [
        %{label: "Intro", slacking_count: 3, struggling_count: 1},
        %{label: "Advanced", slacking_count: 0, struggling_count: 5}
      ]

      config = ChartConfig.stacked_bar_config(rows)

      assert config.type == "bar"
      assert config.data.labels == ["Intro", "Advanced"]
      assert [slacking, struggling] = config.data.datasets
      assert slacking.label == "Slacking"
      assert slacking.data == [3, 0]
      assert struggling.label == "Struggling"
      assert struggling.data == [1, 5]
    end

    test "both datasets share one stack so the bars actually stack, not group" do
      config =
        ChartConfig.stacked_bar_config([%{label: "A", slacking_count: 1, struggling_count: 2}])

      assert [%{stack: stack_1}, %{stack: stack_2}] = config.data.datasets
      assert stack_1 == stack_2
      assert config.options.scales.x.stacked == true
      assert config.options.scales.y.stacked == true
    end

    test "an empty section list still produces a valid, JSON-encodable config" do
      config = ChartConfig.stacked_bar_config([])

      assert config.data.labels == []
      assert [%{data: []}, %{data: []}] = config.data.datasets
      assert {:ok, _json} = Jason.encode(config)
    end
  end

  describe "heatmap_config/1" do
    test "one bubble per non-empty cell, plotted at its own hour/day" do
      cells = [
        %{day_of_week: 1, hour: 9, count: 5},
        %{day_of_week: 3, hour: 22, count: 1},
        %{day_of_week: 5, hour: 14, count: 0}
      ]

      config = ChartConfig.heatmap_config(cells)

      assert config.type == "bubble"
      assert [%{data: data}] = config.data.datasets
      assert length(data) == 2
      assert Enum.find(data, &(&1.x == 9 and &1.y == 1)).count == 5
      assert Enum.find(data, &(&1.x == 22 and &1.y == 3)).count == 1
      refute Enum.find(data, &(&1.x == 14 and &1.y == 5))
    end

    test "the busiest cell gets the largest radius, scaled relative to it" do
      cells = [
        %{day_of_week: 1, hour: 0, count: 10},
        %{day_of_week: 1, hour: 1, count: 5}
      ]

      config = ChartConfig.heatmap_config(cells)
      [%{data: data}] = config.data.datasets

      busiest = Enum.find(data, &(&1.x == 0))
      quieter = Enum.find(data, &(&1.x == 1))

      assert busiest.r > quieter.r
    end

    test "an all-zero grid produces an empty (not crashing) dataset" do
      cells = for day <- 1..7, hour <- 0..23, do: %{day_of_week: day, hour: hour, count: 0}

      config = ChartConfig.heatmap_config(cells)

      assert [%{data: []}] = config.data.datasets
      assert {:ok, _json} = Jason.encode(config)
    end
  end

  describe "funnel_config/1" do
    test "three side-by-side datasets, one value per section in order" do
      rows = [
        %{label: "Intro", opened: 10, interacted: 8, completed: 5},
        %{label: "Advanced", opened: 6, interacted: 2, completed: 1}
      ]

      config = ChartConfig.funnel_config(rows)

      assert config.type == "bar"
      assert config.data.labels == ["Intro", "Advanced"]
      assert [opened, interacted, completed] = config.data.datasets
      assert opened.label == "Opened"
      assert opened.data == [10, 6]
      assert interacted.label == "Interacted"
      assert interacted.data == [8, 2]
      assert completed.label == "Completed"
      assert completed.data == [5, 1]
    end

    test "the three datasets are not stacked (each stage overlaps the one before it)" do
      config = ChartConfig.funnel_config([%{label: "A", opened: 1, interacted: 1, completed: 1}])

      refute Enum.any?(config.data.datasets, &Map.has_key?(&1, :stack))
    end

    test "an empty section list still produces a valid, JSON-encodable config" do
      config = ChartConfig.funnel_config([])

      assert config.data.labels == []
      assert [%{data: []}, %{data: []}, %{data: []}] = config.data.datasets
      assert {:ok, _json} = Jason.encode(config)
    end
  end

  describe "line_config/2" do
    test "one label/value pair per point, dates formatted YYYY-MM-DD, in order" do
      points = [
        %{date: ~D[2026-01-05], value: 3},
        %{date: ~D[2026-01-08], value: 5}
      ]

      config = ChartConfig.line_config(points)

      assert config.type == "line"
      assert config.data.labels == ["2026-01-05", "2026-01-08"]
      assert [%{data: [3, 5]}] = config.data.datasets
    end

    test "opts override the dataset label and color" do
      config =
        ChartConfig.line_config([], dataset_label: "Cohort A", color: "#00ff00")

      assert [%{label: "Cohort A", borderColor: "#00ff00"}] = config.data.datasets
    end

    test "an empty point list still produces a valid, JSON-encodable config" do
      config = ChartConfig.line_config([])

      assert config.data.labels == []
      assert [%{data: []}] = config.data.datasets
      assert {:ok, _json} = Jason.encode(config)
    end
  end

  describe "histogram_config/3" do
    test "one bar per bucket, in bucket order, counts from the histogram" do
      histogram = %{buckets: %{0 => 3, 2 => 1}, bucket_width: 120.0, n: 4}

      config = ChartConfig.histogram_config(histogram, 4)

      assert config.type == "bar"
      assert [%{data: data}] = config.data.datasets
      assert data == [3, 0, 1, 0]
      assert config.data.labels == ["0s+", "120s+", "240s+", "360s+"]
    end

    test "buckets below the percentile floor are painted red, the rest blue" do
      # n: 10, floor 10% -> the first bucket alone (2 students) already
      # covers >= 1 student, so only bucket 0 is red.
      histogram = %{buckets: %{0 => 2, 1 => 8}, bucket_width: 100.0, n: 10}

      config = ChartConfig.histogram_config(histogram, 2, percentile_floor: 10.0)

      assert [%{backgroundColor: [red, blue]}] = config.data.datasets
      assert red == "#ef4444"
      assert blue == "#3b82f6"
    end

    test "every bucket is blue when the floor is 0 (nothing counts as \"below\")" do
      histogram = %{buckets: %{0 => 5}, bucket_width: 100.0, n: 5}

      config = ChartConfig.histogram_config(histogram, 1, percentile_floor: 0.0)

      assert [%{backgroundColor: ["#3b82f6"]}] = config.data.datasets
    end

    test "an empty histogram (n: 0) still produces a valid, JSON-encodable config" do
      histogram = %{buckets: %{}, bucket_width: 120.0, n: 0}

      config = ChartConfig.histogram_config(histogram, 3)

      assert [%{data: [0, 0, 0]}] = config.data.datasets
      assert {:ok, _json} = Jason.encode(config)
    end
  end

  describe "correction_rate_config/1" do
    test "converts each row's 0.0-1.0 rate into a 0-100 percent bar" do
      rows = [
        %{label: "fast dwell", correction_rate: 0.5},
        %{label: "heavy paste", correction_rate: 1.0}
      ]

      config = ChartConfig.correction_rate_config(rows)

      assert config.type == "bar"
      assert config.data.labels == ["fast dwell", "heavy paste"]
      assert [%{data: [50.0, 100.0]}] = config.data.datasets
    end

    test "a nil rate plots as 0, not a crash" do
      config = ChartConfig.correction_rate_config([%{label: "fast dwell", correction_rate: nil}])

      assert [%{data: [0]}] = config.data.datasets
    end

    test "an empty row list still produces a valid, JSON-encodable config" do
      config = ChartConfig.correction_rate_config([])

      assert config.data.labels == []
      assert [%{data: []}] = config.data.datasets
      assert {:ok, _json} = Jason.encode(config)
    end
  end
end
