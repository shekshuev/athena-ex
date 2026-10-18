defmodule AthenaWeb.StudioLive.SurveyChartConfig do
  @moduledoc """
  Pure builders for the Chart.js configs on the survey results screen.

  Same contract as `AthenaWeb.TeachingLive.ChartConfig`: take data
  `Athena.Surveys.Results` has already computed, never touch `Repo`, and
  return a plain `%{type:, data:, options:}` map ready for `Jason.encode!/1`
  into the `data-config` attribute the existing `EngagementChart` hook reads.
  No new JavaScript, and every chart is unit-testable without a browser -
  call the function, assert on the map.

  Every label shown to a reader goes through gettext.

  One deliberate omission: there is no box plot. Chart.js needs a plugin for
  one, and the results screen shows a five-number table plus a bar with error
  bars instead - the same information, no new dependency.
  """
  use Gettext, backend: AthenaWeb.Gettext

  # A single palette for the whole screen so a category keeps its colour from
  # the frequency bar to the crosstab to the group comparison. Taken from the
  # app's own theme tokens rather than invented here.
  @series [
    "oklch(0.65 0.2 255)",
    "oklch(0.7 0.18 155)",
    "oklch(0.75 0.17 85)",
    "oklch(0.65 0.22 25)",
    "oklch(0.6 0.15 300)",
    "oklch(0.7 0.12 200)",
    "oklch(0.55 0.18 340)"
  ]

  @grid "oklch(0.8 0.02 260 / 0.25)"

  @doc "The palette, so a table can colour its key to match its chart."
  @spec series_colours() :: [String.t()]
  def series_colours, do: @series

  @doc """
  A horizontal bar of one question's answer counts.

  Horizontal on purpose: answer labels are sentences more often than words,
  and a vertical bar chart either truncates them or rotates them to be
  unreadable.
  """
  @spec frequency_bar_config(map()) :: map()
  def frequency_bar_config(%{rows: rows}) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(rows, & &1.label),
        datasets: [
          %{
            label: gettext("Answers"),
            data: Enum.map(rows, & &1.count),
            backgroundColor: Enum.map(0..max(length(rows) - 1, 0), &colour/1),
            borderWidth: 0,
            borderRadius: 4
          }
        ]
      },
      options:
        base_options()
        |> Map.put(:indexAxis, "y")
        |> put_in([:plugins, :legend, :display], false)
        |> put_in([:scales], %{
          x: %{beginAtZero: true, ticks: %{precision: 0}, grid: %{color: @grid}},
          y: %{grid: %{display: false}}
        })
    }
  end

  @doc """
  A stacked horizontal bar per matrix row - the conventional Likert plot.

  Reading a battery of items as several separate bar charts makes them
  impossible to compare; stacked to a common width, the shift in where the
  agreement sits is visible at a glance.

  Takes the per-row descriptives from `Results.descriptives/2` plus the raw
  counts per row and point.
  """
  @spec likert_stacked_config([String.t()], [number()], %{
          {String.t(), number()} => non_neg_integer()
        }) :: map()
  def likert_stacked_config(row_labels, points, counts) do
    datasets =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        %{
          label: format_number(point),
          data: Enum.map(row_labels, fn row -> Map.get(counts, {row, point}, 0) end),
          backgroundColor: colour(index),
          borderWidth: 0
        }
      end)

    %{
      type: "bar",
      data: %{labels: row_labels, datasets: datasets},
      options:
        base_options()
        |> Map.put(:indexAxis, "y")
        |> put_in([:plugins, :legend, :position], "bottom")
        |> put_in([:scales], %{
          x: %{stacked: true, beginAtZero: true, ticks: %{precision: 0}, grid: %{color: @grid}},
          y: %{stacked: true, grid: %{display: false}}
        })
    }
  end

  @doc """
  The NPS split as a doughnut: promoters, passives, detractors.

  The three bands are the measure - a mean of 0-10 answers is not an NPS -
  so the chart shows the bands rather than the raw distribution.
  """
  @spec nps_doughnut_config(%{
          promoters: non_neg_integer(),
          passives: non_neg_integer(),
          detractors: non_neg_integer()
        }) :: map()
  def nps_doughnut_config(%{promoters: promoters, passives: passives, detractors: detractors}) do
    %{
      type: "doughnut",
      data: %{
        labels: [
          gettext("Promoters (9-10)"),
          gettext("Passives (7-8)"),
          gettext("Detractors (0-6)")
        ],
        datasets: [
          %{
            data: [promoters, passives, detractors],
            backgroundColor: [colour(1), colour(2), colour(3)],
            borderWidth: 0
          }
        ]
      },
      options:
        base_options()
        |> put_in([:plugins, :legend, :position], "bottom")
        |> Map.put(:cutout, "60%")
    }
  end

  @doc """
  Group means with error bars, drawn as a bar chart plus a floating-bar
  dataset for the interval.

  Chart.js has no error-bar type without a plugin, and a bar chart of means
  alone invites reading a difference that the spread does not support - so the
  interval is drawn as a second, narrow floating bar over each mean. One
  standard error either side, which is what makes two non-overlapping
  intervals worth a second look.
  """
  @spec group_means_config([%{label: String.t(), mean: number() | nil, se: number() | nil}]) ::
          map()
  def group_means_config(groups) do
    labels = Enum.map(groups, & &1.label)
    means = Enum.map(groups, &(&1.mean || 0))

    intervals =
      Enum.map(groups, fn group ->
        case {group.mean, group.se} do
          {mean, se} when is_number(mean) and is_number(se) -> [mean - se, mean + se]
          _ -> nil
        end
      end)

    %{
      type: "bar",
      data: %{
        labels: labels,
        datasets: [
          %{
            label: gettext("Mean"),
            data: means,
            backgroundColor: colour(0),
            borderWidth: 0,
            borderRadius: 4,
            order: 2
          },
          %{
            label: gettext("±1 standard error"),
            data: intervals,
            backgroundColor: "oklch(0.3 0.02 260 / 0.55)",
            borderWidth: 0,
            barPercentage: 0.12,
            order: 1
          }
        ]
      },
      options:
        base_options()
        |> put_in([:plugins, :legend, :position], "bottom")
        |> put_in([:scales], %{
          x: %{grid: %{display: false}},
          y: %{beginAtZero: true, grid: %{color: @grid}}
        })
    }
  end

  @doc """
  The completion funnel: how many people answered each question, in order.

  A line rather than a bar, because the shape of the drop is the finding and
  a line makes the cliff obvious.
  """
  @spec funnel_config([map()]) :: map()
  def funnel_config(steps) do
    %{
      type: "line",
      data: %{
        labels: Enum.with_index(steps, 1) |> Enum.map(fn {_step, index} -> index end),
        datasets: [
          %{
            label: gettext("Answered"),
            data: Enum.map(steps, & &1.answered),
            borderColor: colour(0),
            backgroundColor: "oklch(0.65 0.2 255 / 0.15)",
            fill: true,
            tension: 0.25,
            pointRadius: 3
          },
          %{
            label: gettext("Declined to answer"),
            data: Enum.map(steps, & &1.skipped),
            borderColor: colour(3),
            backgroundColor: "transparent",
            borderDash: [4, 4],
            tension: 0.25,
            pointRadius: 2
          }
        ]
      },
      options:
        base_options()
        |> put_in([:plugins, :legend, :position], "bottom")
        |> put_in([:scales], %{
          x: %{title: %{display: true, text: gettext("Question")}, grid: %{display: false}},
          y: %{beginAtZero: true, ticks: %{precision: 0}, grid: %{color: @grid}}
        })
    }
  end

  @doc """
  A scatter of two questions' answers, for a correlation worth looking at
  rather than only reading a coefficient for.

  Points are jittered a little: on two five-point scales most respondents land
  on the same twenty-five spots, and without jitter the plot shows twenty-five
  dots whatever the sample size. The jitter is deterministic per point, so the
  plot does not shuffle on every re-render.
  """
  @spec scatter_config([{number(), number()}], String.t(), String.t()) :: map()
  def scatter_config(pairs, x_label, y_label) do
    data =
      pairs
      |> Enum.with_index()
      |> Enum.map(fn {{x, y}, index} ->
        %{x: x + jitter(index, 0), y: y + jitter(index, 1)}
      end)

    %{
      type: "scatter",
      data: %{
        datasets: [
          %{
            label: gettext("Respondents"),
            data: data,
            backgroundColor: "oklch(0.65 0.2 255 / 0.5)",
            pointRadius: 4
          }
        ]
      },
      options:
        base_options()
        |> put_in([:plugins, :legend, :display], false)
        |> put_in([:scales], %{
          x: %{title: %{display: true, text: x_label}, grid: %{color: @grid}},
          y: %{title: %{display: true, text: y_label}, grid: %{color: @grid}}
        })
    }
  end

  # A hash, not a random number: the same data must draw the same plot on
  # every render, or the chart appears to move while nothing changed.
  defp jitter(index, axis) do
    :erlang.phash2({index, axis}, 1000) / 1000 * 0.3 - 0.15
  end

  defp colour(index), do: Enum.at(@series, rem(index, length(@series)))

  defp base_options do
    %{
      responsive: true,
      maintainAspectRatio: false,
      plugins: %{legend: %{display: true, labels: %{boxWidth: 12}}}
    }
  end

  defp format_number(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> trunc() |> Integer.to_string(),
      else: to_string(value)
  end

  defp format_number(value), do: to_string(value)
end
