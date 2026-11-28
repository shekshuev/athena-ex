defmodule Athena.Content.MulticodeTest do
  use ExUnit.Case, async: true

  alias Athena.Content
  alias Athena.Content.{Block, Multicode}

  defp variant(code, output \\ "1") do
    %{
      "initial_code" => code,
      "solution_code" => code,
      "test_cases" => [%{"input" => "", "expected_output" => output, "weight" => 100}]
    }
  end

  test "only complete programming languages become student tabs" do
    content = %{
      "languages" => %{
        "python3" => variant("print(1)"),
        "javascript" => variant("console.log(1)"),
        "c" => %{"solution_code" => "reference"},
        "cpp" => %{"test_cases" => [%{"expected_output" => "1"}]},
        "go" => variant("ref", ""),
        "sql" => variant("SELECT 1")
      }
    }

    assert Enum.map(Content.multicode_options(content), &elem(&1, 1)) == ["python3", "javascript"]
    refute Enum.any?(Content.multicode_options(content, true), &(elem(&1, 1) == "sql"))
    assert {:error, :unavailable_language} = Content.code_challenge(:multicode, content, "c")
    assert {:error, :unavailable_language} = Content.code_challenge(:multicode, content, "sql")
  end

  test "ordinary challenge settings are selected per language" do
    content = %{
      "body" => %{"text" => "Shared prompt"},
      "languages" => %{
        "python3" => variant("print(1)"),
        "javascript" =>
          Map.merge(variant("console.log(2)", "2"), %{
            "time_limit" => 3.0,
            "memory_limit" => 131_072
          })
      }
    }

    assert {:ok, challenge} = Content.code_challenge(:multicode, content, "javascript")
    assert challenge.language == "javascript"
    assert challenge.time_limit == 3.0
    assert challenge.memory_limit == 131_072
    assert challenge.solution_code == "console.log(2)"
    assert [%{expected_output: "2"}] = challenge.test_cases
    assert challenge.body == content["body"]
  end

  test "author can save an unfinished test row and edits stay in the active variant" do
    attrs = %{
      "active_language" => "python3",
      "languages" => %{
        "python3" => variant("old"),
        "javascript" => variant("other")
      },
      "solution_code" => "new",
      "test_cases" => [%{"id" => "row", "expected_output" => "", "weight" => 100}]
    }

    changeset = Multicode.changeset(%Multicode{}, attrs)
    assert changeset.valid?
    content = changeset |> Ecto.Changeset.apply_changes() |> Jason.encode!() |> Jason.decode!()
    assert content["languages"]["python3"]["solution_code"] == "new"
    assert content["languages"]["javascript"]["solution_code"] == "other"

    assert [%{"id" => "row", "expected_output" => ""}] =
             content["languages"]["python3"]["test_cases"]

    assert Enum.map(Content.multicode_options(content), &elem(&1, 1)) == ["javascript"]
    refute Multicode.changeset(%Multicode{}, %{"languages" => %{"sql" => %{}}}).valid?
  end

  test "switches preserve unsaved buffers and late autosaves cannot change the active language" do
    block = %Block{
      type: :multicode,
      content: %{
        "languages" => %{
          "python3" => variant("python template"),
          "javascript" => variant("js template")
        }
      }
    }

    js =
      Content.multicode_answer(
        block,
        %{"language" => "javascript", "code" => "unsaved python"},
        nil,
        true
      )

    assert js["code"] == "js template"

    late =
      Content.multicode_answer(block, %{"language" => "python3", "code" => "late python"}, js)

    assert late["language"] == "javascript"
    assert late["code"] == "js template"

    python =
      Content.multicode_answer(
        block,
        %{"language" => "python3", "code" => "unsaved js"},
        late,
        true
      )

    assert python["code"] == "late python"
    assert python["language_drafts"]["javascript"] == "unsaved js"
  end

  test "invalid settings and malformed language maps fail validation" do
    refute Multicode.changeset(%Multicode{}, %{"languages" => "invalid", "solution_code" => "x"}).valid?

    refute Multicode.changeset(%Multicode{}, %{
             "languages" => %{"python3" => %{"time_limit" => 16}}
           }).valid?
  end
end
