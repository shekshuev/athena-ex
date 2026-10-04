defmodule AthenaWeb.FilterComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias AthenaWeb.FilterComponents

  test "renders nothing without active filters" do
    assert render_component(&FilterComponents.active_filters/1, id: "f", filters: []) == ""
  end

  test "one chip per filter, each clearable by key; reset all only with several" do
    one = [%{key: "status", label: "Status", value: "Graded"}]
    html = render_component(&FilterComponents.active_filters/1, id: "f", filters: one)

    assert html =~ ~s(id="f-status")
    assert html =~ "Graded"
    assert html =~ ~s(phx-value-key="status")
    assert html =~ ~s(phx-click="clear_filter")
    refute html =~ "reset_filters"

    two = one ++ [%{key: "login", label: "Student", value: "ivanov"}]

    html =
      render_component(&FilterComponents.active_filters/1,
        id: "f",
        filters: two,
        clear_event: "drop",
        clear_all_event: "drop_all"
      )

    assert html =~ ~s(phx-click="drop")
    assert html =~ ~s(phx-click="drop_all")
  end
end
