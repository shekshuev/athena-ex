defmodule Athena.Execution.SqlValueTest do
  use ExUnit.Case, async: true

  alias Athena.Execution.SqlValue

  describe "to_cell/1" do
    test "keeps numbers and booleans, renders nil as NULL" do
      assert SqlValue.to_cell(42) == 42
      assert SqlValue.to_cell(1.5) == 1.5
      assert SqlValue.to_cell(true) == true
      assert SqlValue.to_cell(nil) == "NULL"
    end

    test "formats intervals like PostgreSQL" do
      assert SqlValue.to_cell(%Postgrex.Interval{months: 7, days: 16, secs: 0, microsecs: 0}) ==
               "7 mons 16 days"

      assert SqlValue.to_cell(%Postgrex.Interval{
               months: 14,
               days: 1,
               secs: 3723,
               microsecs: 500_000
             }) ==
               "1 year 2 mons 1 day 01:02:03.5"

      assert SqlValue.to_cell(%Postgrex.Interval{months: 0, days: 0, secs: 0, microsecs: 0}) ==
               "00:00:00"

      assert SqlValue.to_cell(%Postgrex.Interval{months: 0, days: 0, secs: -90, microsecs: 0}) ==
               "-00:01:30"
    end

    test "renders json maps, arrays, records and ranges as text" do
      assert SqlValue.to_cell(%{"a" => 1}) == ~s({"a":1})
      assert SqlValue.to_cell([1, 2, nil]) == "{1,2,NULL}"
      assert SqlValue.to_cell({1, "x"}) == "(1,x)"

      range = %Postgrex.Range{lower: 1, upper: 5, lower_inclusive: true, upper_inclusive: false}
      assert SqlValue.to_cell(range) == "[1,5)"
    end

    test "keeps valid strings, hex-encodes raw binaries and handles dates" do
      assert SqlValue.to_cell("Крестьянин") == "Крестьянин"
      assert SqlValue.to_cell(<<222, 173, 190, 239>>) == "\\xdeadbeef"
      assert SqlValue.to_cell(~D[1696-02-01]) == "1696-02-01"
    end

    test "never raises on unknown structs" do
      assert is_binary(SqlValue.to_cell(%Postgrex.Point{x: 1.0, y: 2.0}))
    end
  end
end
