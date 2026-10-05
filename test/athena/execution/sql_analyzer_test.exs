defmodule Athena.Execution.SqlAnalyzerTest do
  use ExUnit.Case, async: true

  alias Athena.Execution.SqlAnalyzer

  describe "top_level_order_by?/1" do
    test "detects a plain ORDER BY regardless of case and whitespace" do
      assert SqlAnalyzer.top_level_order_by?("select * from t order by id")
      assert SqlAnalyzer.top_level_order_by?("SELECT * FROM t\n  ORDER\n  BY id DESC NULLS LAST;")
    end

    test "is false without ORDER BY" do
      refute SqlAnalyzer.top_level_order_by?("SELECT * FROM t")
      refute SqlAnalyzer.top_level_order_by?(nil)
    end

    test "ignores ORDER BY nested in parentheses" do
      refute SqlAnalyzer.top_level_order_by?("SELECT id, row_number() OVER (ORDER BY id) FROM t")

      refute SqlAnalyzer.top_level_order_by?(
               "SELECT * FROM (SELECT * FROM t ORDER BY id LIMIT 3) s"
             )

      assert SqlAnalyzer.top_level_order_by?(
               "SELECT * FROM (SELECT * FROM t ORDER BY id LIMIT 3) s ORDER BY name"
             )
    end

    test "ignores comments, string literals and quoted identifiers" do
      refute SqlAnalyzer.top_level_order_by?("SELECT 1 -- order by id\n")
      refute SqlAnalyzer.top_level_order_by?("SELECT 1 /* order by id */")
      refute SqlAnalyzer.top_level_order_by?("SELECT 'order by x' FROM t")
      refute SqlAnalyzer.top_level_order_by?(~s(SELECT "order by" FROM t))
    end
  end
end
