defmodule AthenaWeb.StudioLive.SurveyChartConfigTest do
  @moduledoc """
  Chart configs are plain data, so they are tested as plain data - no browser,
  no LiveView. That is the whole reason chart shape lives in a pure module
  instead of inline in a template.
  """
  use ExUnit.Case, async: true

  alias AthenaWeb.StudioLive.SurveyChartConfig, as: Charts

  defp encodable?(config), do: is_binary(Jason.encode!(config))

  describe "frequency_bar_config/1" do
    test "is a horizontal bar of the counts, in the given row order" do
      config =
        Charts.frequency_bar_config(%{
          rows: [
            %{label: "Too fast", count: 3},
            %{label: "About right", count: 7},
            %{label: "Too slow", count: 1}
          ]
        })

      assert config.type == "bar"
      assert config.data.labels == ["Too fast", "About right", "Too slow"]
      assert [dataset] = config.data.datasets
      assert dataset.data == [3, 7, 1]

      # Horizontal, because answer labels are sentences more often than words.
      assert config.options.indexAxis == "y"
      assert encodable?(config)
    end

    test "colours every bar and survives a palette wrap" do
      rows = for n <- 1..12, do: %{label: "Option #{n}", count: n}

      config = Charts.frequency_bar_config(%{rows: rows})

      [dataset] = config.data.datasets
      assert length(dataset.backgroundColor) == 12
      assert Enum.all?(dataset.backgroundColor, &is_binary/1)
    end

    test "handles an empty distribution without blowing up" do
      config = Charts.frequency_bar_config(%{rows: []})

      assert config.data.labels == []
      assert encodable?(config)
    end
  end

  describe "likert_stacked_config/3" do
    test "one dataset per scale point, stacked on both axes" do
      rows = ["Clear", "Useful"]
      points = [1.0, 2.0, 3.0]

      counts = %{
        {"Clear", 1.0} => 2,
        {"Clear", 3.0} => 5,
        {"Useful", 2.0} => 4
      }

      config = Charts.likert_stacked_config(rows, points, counts)

      assert config.data.labels == rows
      assert length(config.data.datasets) == 3
      assert Enum.map(config.data.datasets, & &1.label) == ["1", "2", "3"]

      # A missing cell is a zero, not a gap: the bars have to add to the same
      # width for the comparison to mean anything.
      [one, two, three] = Enum.map(config.data.datasets, & &1.data)
      assert one == [2, 0]
      assert two == [0, 4]
      assert three == [5, 0]

      assert config.options.scales.x.stacked
      assert config.options.scales.y.stacked
      assert encodable?(config)
    end
  end

  describe "nps_doughnut_config/1" do
    test "shows the three bands, which are the measure" do
      config = Charts.nps_doughnut_config(%{promoters: 10, passives: 5, detractors: 3})

      assert config.type == "doughnut"
      assert [dataset] = config.data.datasets
      assert dataset.data == [10, 5, 3]
      assert Enum.at(config.data.labels, 0) =~ "9-10"
      assert encodable?(config)
    end
  end

  describe "group_means_config/1" do
    test "draws the interval as a second dataset over the means" do
      config =
        Charts.group_means_config([
          %{label: "Group A", mean: 4.5, se: 0.25},
          %{label: "Group B", mean: 2.0, se: 0.5}
        ])

      assert config.data.labels == ["Group A", "Group B"]
      assert [means, intervals] = config.data.datasets
      assert means.data == [4.5, 2.0]

      # Chart.js has no error-bar type without a plugin, so the interval is a
      # narrow floating bar - a chart of means alone invites reading a
      # difference the spread does not support.
      assert intervals.data == [[4.25, 4.75], [1.5, 2.5]]
      assert intervals.barPercentage < 0.3
      assert encodable?(config)
    end

    test "a group with no spread gets no interval rather than a zero-width one" do
      config = Charts.group_means_config([%{label: "Alone", mean: 3.0, se: nil}])

      assert [_means, intervals] = config.data.datasets
      assert intervals.data == [nil]
      assert encodable?(config)
    end
  end

  describe "funnel_config/1" do
    test "plots answered and declined as two lines" do
      steps = [
        %{answered: 20, skipped: 0},
        %{answered: 18, skipped: 2},
        %{answered: 9, skipped: 1}
      ]

      config = Charts.funnel_config(steps)

      assert config.type == "line"
      assert config.data.labels == [1, 2, 3]
      assert [answered, skipped] = config.data.datasets
      assert answered.data == [20, 18, 9]
      assert skipped.data == [0, 2, 1]
      assert encodable?(config)
    end
  end

  describe "scatter_config/3" do
    test "jitters points deterministically so the plot does not move" do
      pairs = [{3, 4}, {3, 4}, {5, 1}]

      first = Charts.scatter_config(pairs, "Pace", "Clarity")
      again = Charts.scatter_config(pairs, "Pace", "Clarity")

      # The same data must draw the same plot on every render, or the chart
      # appears to move while nothing changed.
      assert first == again

      [dataset] = first.data.datasets
      [a, b, _c] = dataset.data

      # Two respondents on the same point are still two visible dots.
      refute a == b
      assert abs(a.x - 3) < 0.2
      assert first.options.scales.x.title.text == "Pace"
      assert encodable?(first)
    end
  end

  test "the palette is shared so a category keeps its colour across charts" do
    assert length(Charts.series_colours()) > 3
    assert Enum.all?(Charts.series_colours(), &is_binary/1)
  end
end
