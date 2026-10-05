defmodule Athena.Execution.SqlValue do
  @moduledoc """
  Converts values decoded by Postgrex into JSON-safe cells for the result table.

  Mirrors PostgreSQL's text output where practical (`interval`, arrays, ranges,
  `bytea`), and never raises: unknown values fall back to `inspect/1`.
  """

  @doc """
  Returns a JSON-encodable representation of a single result cell.

  Numbers and booleans are kept as is, `nil` becomes `"NULL"`, everything else
  becomes a string.
  """
  @spec to_cell(term()) :: String.t() | number() | boolean()
  def to_cell(nil), do: "NULL"
  def to_cell(val) when is_number(val) or is_boolean(val), do: val
  def to_cell(val), do: text(val)

  defp text(nil), do: "NULL"

  defp text(val) when is_binary(val) do
    if String.printable?(val), do: val, else: "\\x" <> Base.encode16(val, case: :lower)
  end

  defp text(%Postgrex.Interval{} = interval), do: interval_text(interval)

  defp text(%Postgrex.INET{address: address, netmask: netmask}) do
    ip = address |> :inet.ntoa() |> List.to_string()
    if netmask, do: "#{ip}/#{netmask}", else: ip
  end

  defp text(%Postgrex.Range{} = range), do: range_text(range)

  defp text(val) when is_map(val) and not is_struct(val), do: Jason.encode!(val)

  defp text(val) when is_list(val), do: "{" <> Enum.map_join(val, ",", &text/1) <> "}"

  defp text(val) when is_tuple(val),
    do: "(" <> (val |> Tuple.to_list() |> Enum.map_join(",", &text/1)) <> ")"

  defp text(val) do
    if String.Chars.impl_for(val), do: to_string(val), else: inspect(val)
  end

  # PostgreSQL "postgres" IntervalStyle, e.g. `1 year 7 mons 16 days 01:02:03.5`.
  defp interval_text(%Postgrex.Interval{months: months, days: days, secs: secs, microsecs: us}) do
    {years, mons} = {div(months, 12), rem(months, 12)}

    [
      unit(years, "year"),
      unit(mons, "mon"),
      unit(days, "day"),
      time_text(secs, us)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "00:00:00"
      parts -> Enum.join(parts, " ")
    end
  end

  defp unit(0, _name), do: nil
  defp unit(1, name), do: "1 #{name}"
  defp unit(n, name), do: "#{n} #{name}s"

  defp time_text(0, 0), do: nil

  defp time_text(secs, us) do
    total_us = secs * 1_000_000 + us
    sign = if total_us < 0, do: "-", else: ""
    abs_us = abs(total_us)

    whole = div(abs_us, 1_000_000)
    frac = rem(abs_us, 1_000_000)
    [h, m, s] = [div(whole, 3600), div(rem(whole, 3600), 60), rem(whole, 60)]

    base = "#{sign}#{pad(h)}:#{pad(m)}:#{pad(s)}"

    if frac == 0 do
      base
    else
      base <>
        "." <>
        (frac |> Integer.to_string() |> String.pad_leading(6, "0") |> String.trim_trailing("0"))
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp range_text(%Postgrex.Range{lower: lower, upper: upper} = r) do
    open = if r.lower_inclusive, do: "[", else: "("
    close = if r.upper_inclusive, do: "]", else: ")"
    "#{open}#{bound(lower)},#{bound(upper)}#{close}"
  end

  defp bound(:unbound), do: ""
  defp bound(:empty), do: ""
  defp bound(val), do: text(val)
end
