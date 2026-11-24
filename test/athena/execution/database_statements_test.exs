defmodule Athena.Execution.DatabaseStatementsTest do
  use ExUnit.Case, async: true
  alias Athena.Execution.Database.Statements

  test "splits scripts while preserving strings, identifiers, escapes and UTF-8" do
    assert {:ok, ["SELECT 'я;--/*#'", "SELECT `semi;colon`, 'it\\'s;fine'", "SELECT \"a;\"\"b\""]} =
             Statements.split(
               "-- hidden;\nSELECT 'я;--/*#'; /* hidden; */ SELECT `semi;colon`, 'it\\'s;fine'; # hidden;\n SELECT \"a;\"\"b\";"
             )
  end

  test "MySQL subtraction and ClickHouse comments keep their dialect semantics" do
    assert {:ok, ["SELECT 1--1"]} = Statements.split("SELECT 1--1", "mysql")
    assert {:ok, ["SELECT 1"]} = Statements.split("SELECT 1--comment", "clickhouse")
  end

  test "rejects malformed and executable comments instead of running hidden commands" do
    for sql <- [
          "SELECT 'unfinished",
          "SELECT 1 /* unfinished",
          "/*! SET max_statement_time=0 */ SELECT 1",
          "/*M! SET max_statement_time=0 */ SELECT 1"
        ] do
      assert {:error, {:sql_error, _}} = Statements.split(sql)
    end

    assert {:error, {:sql_error, _}} = Statements.single("SELECT 1; SELECT 2")
    assert {:error, {:sql_error, _}} = Statements.single("-- nothing")
  end

  test "identifies result statements without mistaking quoted text for RETURNING" do
    assert Statements.words("INSERT INTO t VALUES ('RETURNING')") == [
             "INSERT",
             "INTO",
             "T",
             "VALUES"
           ]

    assert Statements.words("INSERT INTO t VALUES (1) RETURNING id") == [
             "INSERT",
             "INTO",
             "T",
             "VALUES",
             "RETURNING",
             "ID"
           ]
  end
end
