defmodule AthenaWeb.TeachingLive.ChartConfig do
  @moduledoc """
  Pure builders for the Chart.js configs rendered by the `Athena.Engagement`
  dashboards (`CohortEngagement`, `CourseEngagementCompare`).

  Every function here takes data that has already been computed by
  `Athena.Engagement`/`Athena.Learning` (never touches `Repo` itself) and
  returns a plain map shaped like a Chart.js `{type, data, options}` config,
  ready for `Jason.encode!/1` into a `data-config` attribute read by the
  `EngagementChart` JS hook (`assets/js/charts_hooks.js`). Keeping chart
  shape here instead of inline in a LiveView's `render/1` is what makes each
  chart unit-testable without a browser: call the function, assert on the
  returned map.
  """

  @doc """
  A scatter plot from `points` (`%{x:, y:, label:}` maps - `label` is
  carried through into each Chart.js data point so tooltips can show it,
  even though the axes only plot `x`/`y`).

  Used for the "Student Radar" screen's slacking-index × struggling-index
  plot: one point per student, so an outlier is visible without reading
  every row of the table it sits above.
  """
  @spec scatter_config([%{x: number(), y: number(), label: String.t()}], keyword()) :: map()
  def scatter_config(points, opts \\ []) do
    %{
      type: "scatter",
      data: %{
        datasets: [
          %{
            label: Keyword.get(opts, :dataset_label, "Students"),
            data: Enum.map(points, fn p -> %{x: p.x, y: p.y, label: p.label} end),
            backgroundColor: Keyword.get(opts, :color, "#ef4444")
          }
        ]
      },
      options: %{
        scales: %{
          x: %{
            title: %{display: true, text: Keyword.get(opts, :x_label, "X")},
            beginAtZero: true
          },
          y: %{
            title: %{display: true, text: Keyword.get(opts, :y_label, "Y")},
            beginAtZero: true
          }
        },
        plugins: %{legend: %{display: false}}
      }
    }
  end

  @default_colors ["#ef4444", "#3b82f6", "#22c55e", "#f59e0b", "#8b5cf6"]

  @doc """
  A radar/spider chart overlaying one polygon per `series` entry
  (`%{label:, values: %{axis => rate}, color: "#rrggbb" | nil}`) across a
  shared, ordered `axes` list - the "Cohort Comparison" chart: one polygon
  per cohort, axes = `Athena.Engagement.Metrics.cohort_flag_profile/3`'s
  flag names, so where one cohort's shape bulges out on `paste_ratio` and
  another's on `backtrack_rate` is visible at a glance. Missing values
  (an axis absent from a series' `values`) plot as `0.0` rather than
  crashing - a cohort simply hasn't produced that flag yet, not an error.
  Colors default to a small fixed palette, cycled by position, when a
  series doesn't specify one (hex colors only - a translucent fill is
  derived by appending an alpha suffix).
  """
  @spec radar_config([atom() | String.t()], [
          %{
            required(:label) => String.t(),
            required(:values) => %{atom() => number()},
            optional(:color) => String.t()
          }
        ]) :: map()
  def radar_config(axes, series, opts \\ []) do
    datasets =
      series
      |> Enum.with_index()
      |> Enum.map(fn {s, index} ->
        color =
          Map.get(s, :color) || Enum.at(@default_colors, rem(index, length(@default_colors)))

        %{
          label: s.label,
          data: Enum.map(axes, &Map.get(s.values, &1, 0.0)),
          borderColor: color,
          backgroundColor: color <> "33"
        }
      end)

    %{
      type: "radar",
      data: %{labels: Enum.map(axes, &humanize_axis/1), datasets: datasets},
      options: %{scales: %{r: %{min: 0, max: Keyword.get(opts, :max, 1.0)}}}
    }
  end

  defp humanize_axis(axis) when is_atom(axis), do: axis |> to_string() |> String.replace("_", " ")
  defp humanize_axis(axis) when is_binary(axis), do: axis

  @doc """
  A two-series stacked bar chart from `rows` (`%{label:, slacking_count:,
  struggling_count:}` maps, one per course section) - slacking (red) and
  struggling (yellow) stacked on top of each other per section, so a
  section where either color towers over the rest is visible without
  reading every block's badge underneath it.
  """
  @spec stacked_bar_config([
          %{label: String.t(), slacking_count: number(), struggling_count: number()}
        ]) :: map()
  def stacked_bar_config(rows) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(rows, & &1.label),
        datasets: [
          %{
            label: "Slacking",
            data: Enum.map(rows, & &1.slacking_count),
            backgroundColor: "#ef4444",
            stack: "flags"
          },
          %{
            label: "Struggling",
            data: Enum.map(rows, & &1.struggling_count),
            backgroundColor: "#f59e0b",
            stack: "flags"
          }
        ]
      },
      options: %{
        scales: %{
          x: %{stacked: true},
          y: %{stacked: true, beginAtZero: true, ticks: %{precision: 0}}
        }
      }
    }
  end

  @doc """
  A day-of-week x hour-of-day activity heatmap from `cells` (`%{day_of_week:
  1..7, hour: 0..23, count:}` maps, `Athena.Engagement.Metrics.
  activity_heatmap/3`'s exact shape - `1` = Monday .. `7` = Sunday) -
  Chart.js has no built-in heatmap type without an extra plugin, so this
  renders it as a bubble chart instead (x = hour, y = day, bubble radius
  scaled to that cell's share of the busiest cell) - the same visual read
  (bigger circle = busier slot) as a heatmap, no new dependency. Empty
  (`count: 0`) cells are dropped from the dataset rather than plotted as
  zero-radius bubbles. The y-axis is left numeric (no day-name labels) -
  Chart.js tick labels need a JS callback, which would mean this config
  stops being plain, testable data, so the axis title documents the
  Mon-Sun convention instead.
  """
  @spec heatmap_config([%{day_of_week: 1..7, hour: 0..23, count: non_neg_integer()}]) :: map()
  def heatmap_config(cells) do
    max_count = cells |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)

    data =
      cells
      |> Enum.filter(&(&1.count > 0))
      |> Enum.map(fn cell ->
        %{
          x: cell.hour,
          y: cell.day_of_week,
          r: bubble_radius(cell.count, max_count),
          count: cell.count
        }
      end)

    %{
      type: "bubble",
      data: %{
        datasets: [%{label: "Activity", data: data, backgroundColor: "#3b82f6b3"}]
      },
      options: %{
        scales: %{
          x: %{
            title: %{display: true, text: "Hour (UTC)"},
            min: -1,
            max: 24,
            ticks: %{stepSize: 3}
          },
          y: %{
            title: %{display: true, text: "Day of week (1 = Mon, 7 = Sun)"},
            min: 0,
            max: 8,
            ticks: %{stepSize: 1}
          }
        },
        plugins: %{legend: %{display: false}}
      }
    }
  end

  defp bubble_radius(_count, 0), do: 0
  defp bubble_radius(count, max_count), do: 3 + count / max_count * 12

  @doc """
  A three-series grouped bar chart from `rows` (`%{label:, opened:,
  interacted:, completed:}` maps, one per course section,
  `Athena.Engagement.Metrics.course_funnel/3`'s exact shape) - side by side
  rather than stacked, since each stage is a subset of the one before it
  (stacking would double-count), so the *drop* between bars is what a
  teacher reads: a section where "completed" is much shorter than "opened"
  is where the course structurally loses the cohort.
  """
  @spec funnel_config([
          %{label: String.t(), opened: number(), interacted: number(), completed: number()}
        ]) :: map()
  def funnel_config(rows) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(rows, & &1.label),
        datasets: [
          %{label: "Opened", data: Enum.map(rows, & &1.opened), backgroundColor: "#3b82f6"},
          %{
            label: "Interacted",
            data: Enum.map(rows, & &1.interacted),
            backgroundColor: "#8b5cf6"
          },
          %{label: "Completed", data: Enum.map(rows, & &1.completed), backgroundColor: "#22c55e"}
        ]
      },
      options: %{
        scales: %{y: %{beginAtZero: true, ticks: %{precision: 0}}}
      }
    }
  end

  @doc """
  A single-series line chart from `points` (`%{date: Date.t(), value:
  number()}` maps) - used for the "active students" pulse trend
  (`Athena.Engagement.Metrics.active_students_trend/3`'s `active_count`
  renamed to the generic `value` here so this builder isn't tied to one
  specific metric) and reusable for any other day-indexed series later.
  Dates are formatted with `Date.to_string/1` (`YYYY-MM-DD`) since Chart.js
  category-axis labels are plain strings, not date objects.
  """
  @spec line_config([%{date: Date.t(), value: number()}], keyword()) :: map()
  def line_config(points, opts \\ []) do
    %{
      type: "line",
      data: %{
        labels: Enum.map(points, &Date.to_string(&1.date)),
        datasets: [
          %{
            label: Keyword.get(opts, :dataset_label, "Active students"),
            data: Enum.map(points, & &1.value),
            borderColor: Keyword.get(opts, :color, "#3b82f6"),
            backgroundColor: Keyword.get(opts, :color, "#3b82f6"),
            tension: 0.2
          }
        ]
      },
      options: %{
        scales: %{y: %{beginAtZero: true, ticks: %{precision: 0}}},
        plugins: %{legend: %{display: false}}
      }
    }
  end

  @doc """
  A bar chart of `histogram` (`Athena.Engagement.BlockStats.histogram/2`'s
  exact shape - `%{buckets:, bucket_width:, n:}`) over `bucket_count`
  buckets, with the bottom `opts[:percentile_floor]` percent (default
  `10.0`, matching `Athena.Engagement.nudge_percentile_floor/0`) of
  students painted red instead of blue - the "why did the algorithm nudge
  this student" chart: it draws the exact distribution and cutoff
  `evaluate_nudge/5` reasons against, from the bottom bucket upward, not a
  guessed number. Chart.js has no vertical-line annotation without an
  extra plugin, so the cutoff is shown as a color split between bars
  instead - a bucket is painted red only once every student below it is
  accounted for, so the split lands on a bucket boundary, not a fractional
  cut through one bar (an approximation in the same spirit as
  `BlockStats`'s own "approximate percentile rank").
  """
  @spec histogram_config(
          %{
            buckets: %{non_neg_integer() => non_neg_integer()},
            bucket_width: float(),
            n: number()
          },
          pos_integer(),
          keyword()
        ) :: map()
  def histogram_config(histogram, bucket_count, opts \\ []) do
    floor_percentile = Keyword.get(opts, :percentile_floor, 10.0)
    target = histogram.n * floor_percentile / 100

    {counts, colors, _cumulative} =
      Enum.reduce(0..(bucket_count - 1), {[], [], 0}, fn index,
                                                         {counts_acc, colors_acc, cumulative} ->
        count = Map.get(histogram.buckets, index, 0)
        color = if cumulative < target, do: "#ef4444", else: "#3b82f6"
        {[count | counts_acc], [color | colors_acc], cumulative + count}
      end)

    labels =
      for index <- 0..(bucket_count - 1) do
        "#{round(index * histogram.bucket_width)}s+"
      end

    %{
      type: "bar",
      data: %{
        labels: labels,
        datasets: [
          %{label: "Students", data: Enum.reverse(counts), backgroundColor: Enum.reverse(colors)}
        ]
      },
      options: %{
        scales: %{y: %{beginAtZero: true, ticks: %{precision: 0}}},
        plugins: %{legend: %{display: false}}
      }
    }
  end

  @doc """
  A single-series bar chart from `rows` (`%{label:, correction_rate: float
  | nil}` maps, one per nudge reason,
  `Athena.Engagement.Metrics.nudge_correction_rate/3`'s exact shape,
  `correction_rate` as a 0.0-1.0 fraction) - the "did the nudge actually
  change behavior" chart, one bar per reason, plotted as a 0-100 percent.
  A `nil` rate (nothing was ever nudged for that reason) plots as `0` -
  documented here since a `0` bar and a `nil` rate read identically on a
  bar chart; the caller decides whether that ambiguity matters for its
  audience (it doesn't for this one - `nudge_correction_rate/3` only ever
  returns reasons that were actually nudged at least once).
  """
  @spec correction_rate_config([%{label: String.t(), correction_rate: float() | nil}]) :: map()
  def correction_rate_config(rows) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(rows, & &1.label),
        datasets: [
          %{
            label: "Correction rate (%)",
            data: Enum.map(rows, &correction_percent/1),
            backgroundColor: "#22c55e"
          }
        ]
      },
      options: %{
        scales: %{y: %{beginAtZero: true, max: 100}},
        plugins: %{legend: %{display: false}}
      }
    }
  end

  defp correction_percent(%{correction_rate: nil}), do: 0
  defp correction_percent(%{correction_rate: rate}), do: Float.round(rate * 100, 1)
end
