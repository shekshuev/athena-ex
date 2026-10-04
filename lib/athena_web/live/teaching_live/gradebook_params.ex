defmodule AthenaWeb.TeachingLive.GradebookParams do
  @moduledoc """
  The gradebook's filter/sort/display state, kept entirely in the URL query
  string so any view of it can be bookmarked or sent to a colleague, and so
  the CSV export downloads exactly what is on screen.

  `parse/1` turns query params into a normalized map (unknown or invalid
  values fall back to defaults - never trusted, never turned into atoms
  outside the known sets); `to_query/1` is its inverse and leaves defaults
  out, so a pristine gradebook has a clean URL.
  """

  alias Athena.Engagement
  alias Athena.Learning.Gradebook

  @types ~w(code quiz_question quiz_exam ticket_exam file_assignment)a
  @displays [:score, :pass]
  @sorts ["name", "average", "passed"]
  @thresholds [50, 60, 70, 75, 80, 90]

  @type t :: %{
          account_ids: [binary()] | nil,
          block_ids: [binary()] | nil,
          types: [atom()],
          from: Date.t() | nil,
          to: Date.t() | nil,
          attempt: atom(),
          status: atom(),
          threshold: pos_integer(),
          display: atom(),
          compact: boolean(),
          collapsed: [binary()],
          sort: String.t(),
          dir: :asc | :desc,
          layer: :scores | :engagement,
          theory: boolean(),
          level: atom() | nil
        }

  @doc "Gradable block types, in the order filter chips show them."
  def types, do: @types

  @doc "Pass marks a teacher can pick from."
  def thresholds, do: @thresholds

  @doc "The state of an untouched gradebook."
  @spec defaults() :: t()
  def defaults do
    %{
      account_ids: nil,
      block_ids: nil,
      types: [],
      from: nil,
      to: nil,
      attempt: :best,
      status: :all,
      threshold: Gradebook.default_threshold(),
      display: :score,
      compact: false,
      collapsed: [],
      sort: "name",
      dir: :asc,
      layer: :scores,
      theory: false,
      level: nil
    }
  end

  @spec parse(map()) :: t()
  def parse(params) when is_map(params) do
    defaults = defaults()

    %{
      account_ids: id_list(params["students"]),
      block_ids: id_list(params["blocks"]),
      types: params["types"] |> csv() |> Enum.flat_map(&known(&1, @types)),
      from: date(params["from"]),
      to: date(params["to"]),
      attempt: one_of(params["attempt"], Gradebook.attempt_policies(), defaults.attempt),
      status: one_of(params["status"], Gradebook.status_filters(), defaults.status),
      threshold: threshold(params["threshold"], defaults.threshold),
      display: one_of(params["display"], @displays, defaults.display),
      compact: params["compact"] == "1",
      collapsed: params["collapsed"] |> csv() |> Enum.filter(&uuid?/1),
      sort: sort(params["sort"]),
      dir: if(params["dir"] == "desc", do: :desc, else: :asc),
      layer: one_of(params["layer"], [:scores, :engagement], defaults.layer),
      theory: params["theory"] == "1",
      level: one_of(params["level"], Engagement.assessment_levels(), nil)
    }
  end

  @doc "Query params for `filters`, with every default value left out."
  @spec to_query(t()) :: map()
  def to_query(filters) do
    defaults = defaults()

    [
      {"students", join_ids(filters.account_ids)},
      {"blocks", join_ids(filters.block_ids)},
      {"types", join(filters.types)},
      {"from", filters.from && Date.to_iso8601(filters.from)},
      {"to", filters.to && Date.to_iso8601(filters.to)},
      {"attempt", unless_default(filters.attempt, defaults.attempt)},
      {"status", unless_default(filters.status, defaults.status)},
      {"threshold", unless_default(filters.threshold, defaults.threshold)},
      {"display", unless_default(filters.display, defaults.display)},
      {"compact", if(filters.compact, do: "1")},
      {"collapsed", join(filters.collapsed)},
      {"sort", unless_default(filters.sort, defaults.sort)},
      {"dir", unless_default(filters.dir, defaults.dir)},
      {"layer", unless_default(filters.layer, defaults.layer)},
      {"theory", if(filters.theory, do: "1")},
      {"level", filters.level}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
  end

  @doc """
  How many filters narrow what is shown (students, blocks, types, dates,
  status) - for the "N filters" badge next to "Reset". Display choices
  (attempt policy, pass mark, view mode, sort) are not counted.
  """
  @spec active_count(t()) :: non_neg_integer()
  def active_count(filters) do
    Enum.count(
      [
        filters.account_ids != nil,
        filters.block_ids != nil,
        filters.types != [],
        filters.from != nil or filters.to != nil,
        filters.status != :all,
        filters.level != nil
      ],
      & &1
    )
  end

  defp csv(nil), do: []
  defp csv(value) when is_binary(value), do: value |> String.split(",", trim: true)
  defp csv(_value), do: []

  # `nil` means "no restriction"; `[]` means "nothing selected" (a teacher
  # unticked everyone), which must survive a round trip through the URL -
  # an empty param would be dropped, so it is spelled `-`.
  defp id_list(nil), do: nil
  defp id_list("-"), do: []
  defp id_list(value) when is_binary(value), do: value |> csv() |> Enum.filter(&uuid?/1)
  defp id_list(_value), do: nil

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp known(value, allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> []
      atom -> [atom]
    end
  end

  defp one_of(value, allowed, default) when is_binary(value) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp one_of(_value, _allowed, default), do: default

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_value), do: nil

  defp threshold(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number in 1..100 -> number
      _ -> default
    end
  end

  defp threshold(_value, default), do: default

  defp sort("block:" <> id = value), do: if(uuid?(id), do: value, else: "name")
  defp sort(value) when value in @sorts, do: value
  defp sort(_value), do: "name"

  defp join_ids([]), do: "-"
  defp join_ids(ids), do: join(ids)

  defp join(nil), do: nil
  defp join(list), do: Enum.join(list, ",")

  defp unless_default(value, value), do: nil
  defp unless_default(value, _default), do: value
end
