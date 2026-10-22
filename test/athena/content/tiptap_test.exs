defmodule Athena.Content.TiptapTest do
  use ExUnit.Case, async: true

  alias Athena.Content.Tiptap

  doctest Tiptap

  defp text(marks), do: %{"type" => "text", "text" => "hi", "marks" => marks}

  describe "strip_colors/1" do
    test "drops a textStyle mark that only carried a colour" do
      doc = %{
        "type" => "doc",
        "content" => [text([%{"type" => "textStyle", "attrs" => %{"color" => "#000000"}}])]
      }

      assert %{"content" => [%{"marks" => []}]} = Tiptap.strip_colors(doc)
    end

    test "keeps a textStyle mark that still has other attributes" do
      marks = [%{"type" => "textStyle", "attrs" => %{"color" => "#000", "fontFamily" => "serif"}}]

      assert %{"marks" => [mark]} = Tiptap.strip_colors(text(marks))
      assert mark == %{"type" => "textStyle", "attrs" => %{"fontFamily" => "serif"}}
    end

    test "leaves other marks alone" do
      marks = [%{"type" => "bold"}, %{"type" => "highlight", "attrs" => %{"color" => "#ff0"}}]

      assert %{"marks" => ^marks} = Tiptap.strip_colors(text(marks))
    end

    test "strips backgroundColor as well" do
      marks = [%{"type" => "textStyle", "attrs" => %{"backgroundColor" => "#fff"}}]

      assert %{"marks" => []} = Tiptap.strip_colors(text(marks))
    end

    test "walks a block's whole content payload, not just a bare document" do
      colored = text([%{"type" => "textStyle", "attrs" => %{"color" => "#111"}}])

      content = %{
        "question_type" => "single",
        "body" => %{"type" => "doc", "content" => [colored]},
        "options" => [%{"id" => "a", "text" => %{"type" => "doc", "content" => [colored]}}],
        "pairs" => [%{"left" => %{"type" => "doc", "content" => [colored]}}]
      }

      stripped = Tiptap.strip_colors(content)

      refute stripped |> Jason.encode!() |> String.contains?("textStyle")
      assert stripped["question_type"] == "single"
      assert [%{"id" => "a"}] = stripped["options"]
    end

    test "handles atom keys" do
      doc = %{
        type: "doc",
        content: [%{type: "text", marks: [%{type: "textStyle", attrs: %{color: "#000"}}]}]
      }

      assert %{content: [%{marks: []}]} = Tiptap.strip_colors(doc)
    end

    test "is idempotent" do
      doc = %{
        "type" => "doc",
        "content" => [text([%{"type" => "textStyle", "attrs" => %{"color" => "#000"}}])]
      }

      once = Tiptap.strip_colors(doc)

      assert Tiptap.strip_colors(once) == once
    end

    test "returns non-document values untouched" do
      assert Tiptap.strip_colors(nil) == nil
      assert Tiptap.strip_colors("plain") == "plain"
      assert Tiptap.strip_colors(42) == 42
      assert Tiptap.strip_colors([]) == []
    end

    test "cleans a rich answer stored as a JSON string under text_answer" do
      doc = %{
        "type" => "doc",
        "content" => [text([%{"type" => "textStyle", "attrs" => %{"color" => "#000"}}])]
      }

      content = %{"type" => "text", "text_answer" => Jason.encode!(doc)}

      assert %{"text_answer" => answer} = Tiptap.strip_colors(content)
      refute String.contains?(answer, "textStyle")
    end

    test "leaves a plain-text or source-code text_answer alone" do
      code = "x = {\"color\": 1}"

      assert %{"text_answer" => ^code} = Tiptap.strip_colors(%{"text_answer" => code})
    end
  end

  describe "strip_colors_in_doc_string/1" do
    test "only rewrites strings that decode to a document" do
      assert Tiptap.strip_colors_in_doc_string("not json") == "not json"
      assert Tiptap.strip_colors_in_doc_string(~s({"a":1})) == ~s({"a":1})
      assert Tiptap.strip_colors_in_doc_string(nil) == nil
    end
  end
end
