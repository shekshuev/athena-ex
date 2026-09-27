defmodule Athena.TimeZones do
  @moduledoc """
  Single place for timezone rules.

    * Storage and every server-side comparison stay in UTC (`:utc_datetime`).
    * The **app timezone** (`config :athena, :app_timezone`) defines where a
      calendar day/week starts for server logic (daily challenges, weekly
      rollups, cron) - see `today/0`.
    * The **user timezone** is what the browser reports; it's only used at the
      UI edge: shifting UTC values for display (`to_local/1`, `format/2`) and
      turning what a user typed into UTC (`local_to_utc/1`, `localize_params/2`).

  Like Gettext's locale, the user timezone lives in the process dictionary of
  the LiveView process (set by `AthenaWeb.Hooks.Timezone`), so every function
  component and LiveComponent rendered by that process picks it up without
  threading an assign through.
  """

  @key :athena_user_timezone

  @doc "Timezone that defines day/week boundaries for server-side logic."
  @spec app_timezone() :: String.t()
  def app_timezone, do: Application.get_env(:athena, :app_timezone, "Etc/UTC")

  @doc "Today's date in the app timezone."
  @spec today() :: Date.t()
  def today, do: DateTime.utc_now() |> DateTime.shift_zone!(app_timezone()) |> DateTime.to_date()

  @doc "Monday of the current week in the app timezone."
  @spec this_week_start() :: Date.t()
  def this_week_start, do: Date.beginning_of_week(today())

  @doc """
  The UTC instant at which `date` begins in the app timezone - use it to turn
  app-timezone day/week boundaries into `:utc_datetime` query bounds.
  """
  @spec start_of_day(Date.t()) :: DateTime.t()
  def start_of_day(%Date{} = date) do
    case DateTime.new(date, ~T[00:00:00], app_timezone()) do
      {:ok, dt} -> to_utc(dt)
      {:ambiguous, first, _second} -> to_utc(first)
      {:gap, _before, just_after} -> to_utc(just_after)
    end
  end

  @doc "Shifts a UTC datetime into the app timezone (for day/hour bucketing)."
  @spec to_app_zone(DateTime.t()) :: DateTime.t()
  def to_app_zone(%DateTime{} = dt), do: DateTime.shift_zone!(dt, app_timezone())

  @doc "Whether `tz` is a known IANA timezone name."
  @spec valid?(term()) :: boolean()
  def valid?(tz) when is_binary(tz) and tz != "" do
    match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), tz))
  end

  def valid?(_), do: false

  @doc "Stores the current user's timezone for this process (invalid values fall back)."
  @spec put_user_timezone(term()) :: String.t()
  def put_user_timezone(tz) do
    tz = if valid?(tz), do: tz, else: app_timezone()
    Process.put(@key, tz)
    tz
  end

  @doc "Timezone to render and read datetimes in for the current process."
  @spec user_timezone() :: String.t()
  def user_timezone, do: Process.get(@key) || app_timezone()

  @doc "Shifts a UTC datetime into the user timezone. `nil` passes through."
  @spec to_local(DateTime.t() | nil, String.t() | nil) :: DateTime.t() | nil
  def to_local(dt, tz \\ nil)
  def to_local(nil, _tz), do: nil
  def to_local(%DateTime{} = dt, tz), do: DateTime.shift_zone!(dt, tz || user_timezone())

  @doc """
  Formats a UTC datetime in the user timezone with a `Calendar.strftime/2`
  pattern. `nil` renders as an empty string.
  """
  @spec format(DateTime.t() | nil, String.t()) :: String.t()
  def format(nil, _pattern), do: ""
  def format(%DateTime{} = dt, pattern), do: dt |> to_local() |> Calendar.strftime(pattern)

  @doc "Today's date in the user timezone."
  @spec local_today() :: Date.t()
  def local_today, do: DateTime.utc_now() |> to_local() |> DateTime.to_date()

  @doc """
  Interprets a wall-clock value typed by the user (`"2026-09-25T14:00"`,
  `NaiveDateTime`) in the user timezone and returns it in UTC.

  Strings that already carry an offset (`...Z`, `...+03:00`) are absolute and
  are only normalised to UTC. For wall-clock times that fall into a DST gap
  the later instant is used; for ambiguous ones the earlier.
  """
  @spec local_to_utc(String.t() | NaiveDateTime.t() | nil, String.t() | nil) ::
          {:ok, DateTime.t()} | :error
  def local_to_utc(value, tz \\ nil)

  def local_to_utc(%NaiveDateTime{} = ndt, tz) do
    case DateTime.from_naive(ndt, tz || user_timezone()) do
      {:ok, dt} -> {:ok, to_utc(dt)}
      {:ambiguous, first, _second} -> {:ok, to_utc(first)}
      {:gap, _before, just_after} -> {:ok, to_utc(just_after)}
      {:error, _} -> :error
    end
  end

  def local_to_utc(value, tz) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, to_utc(dt)}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(pad_seconds(value)) do
          {:ok, ndt} -> local_to_utc(ndt, tz)
          {:error, _} -> :error
        end
    end
  end

  def local_to_utc(_value, _tz), do: :error

  @doc """
  UTC instant where the given local calendar day (`"YYYY-MM-DD"`) starts in the
  user timezone; `offset_days` shifts the day (pass `1` for an exclusive end
  bound of a date-range filter).
  """
  @spec local_day_start(String.t(), integer()) :: {:ok, DateTime.t()} | :error
  def local_day_start(date_string, offset_days \\ 0) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        date |> Date.add(offset_days) |> NaiveDateTime.new!(~T[00:00:00]) |> local_to_utc()

      {:error, _} ->
        :error
    end
  end

  @doc """
  Rewrites wall-clock datetime params (as submitted by `<.input type="datetime-local">`)
  into UTC ISO8601 strings so the changeset casts the right instant. Blank and
  unparsable values are left untouched for the changeset to validate.
  """
  @spec localize_params(map(), [String.t()]) :: map()
  def localize_params(params, keys) when is_map(params) do
    Enum.reduce(keys, params, fn key, acc ->
      with value when is_binary(value) and value != "" <- Map.get(acc, key),
           {:ok, utc} <- local_to_utc(value) do
        Map.put(acc, key, DateTime.to_iso8601(utc))
      else
        _ -> acc
      end
    end)
  end

  @doc """
  Value for a `datetime-local` input: the wall-clock time in the user timezone
  (`"YYYY-MM-DDTHH:MM"`). Accepts a `DateTime`, an offset-carrying ISO string
  (params after `localize_params/2`) or a bare wall-clock string (returned as is).
  """
  @spec input_value(DateTime.t() | String.t() | nil) :: String.t()
  def input_value(nil), do: ""
  def input_value(""), do: ""

  def input_value(%DateTime{} = dt),
    do: dt |> to_local() |> Calendar.strftime("%Y-%m-%dT%H:%M")

  def input_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> input_value(dt)
      _ -> String.slice(value, 0, 16)
    end
  end

  def input_value(_), do: ""

  defp to_utc(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

  # `datetime-local` submits "YYYY-MM-DDTHH:MM", which NaiveDateTime rejects.
  defp pad_seconds(<<_::binary-size(16)>> = value), do: value <> ":00"
  defp pad_seconds(value), do: value
end
