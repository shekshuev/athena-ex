defmodule AthenaWeb.CoreComponentsTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias AthenaWeb.CoreComponents

  describe "button/1" do
    test "defaults to btn-outline with no variant" do
      html = render_component(&CoreComponents.button/1, %{inner_block: [], __changed__: nil})
      assert html =~ "btn-outline"
    end

    test "renders each variant's expected class" do
      for {variant, expected_class} <- %{
            "primary" => "btn-primary",
            "ghost" => "btn-ghost",
            "danger" => "btn-error",
            "danger_outline" => "btn-error",
            "warning" => "btn-warning"
          } do
        html =
          render_component(&CoreComponents.button/1, %{
            variant: variant,
            inner_block: [],
            __changed__: nil
          })

        assert html =~ expected_class
      end
    end

    test "renders as a link when navigate is given" do
      html =
        render_component(&CoreComponents.button/1, %{
          navigate: "/dashboard",
          inner_block: [],
          __changed__: nil
        })

      assert html =~ ~s(href="/dashboard")
    end
  end

  describe "icon_button/1" do
    test "renders neutral by default with the given icon and label" do
      html =
        render_component(&CoreComponents.icon_button/1, %{
          icon: "hero-pencil-square",
          label: "Edit"
        })

      assert html =~ "hero-pencil-square"
      assert html =~ ~s(aria-label="Edit")
      refute html =~ "text-error"
    end

    test "danger variant adds the destructive treatment" do
      html =
        render_component(&CoreComponents.icon_button/1, %{
          icon: "hero-trash",
          label: "Delete",
          variant: "danger"
        })

      assert html =~ "text-error"
    end

    test "renders as a link when patch is given" do
      html =
        render_component(&CoreComponents.icon_button/1, %{
          icon: "hero-pencil-square",
          label: "Edit",
          patch: "/admin/users/123/edit"
        })

      assert html =~ ~s(href="/admin/users/123/edit")
    end
  end

  describe "badge/1" do
    test "defaults to neutral tone" do
      html =
        render_component(&CoreComponents.badge/1, %{
          inner_block: [%{inner_block: fn _, _ -> "Draft" end}]
        })

      assert html =~ "badge-neutral"
      assert html =~ "badge-soft"
      assert html =~ "Draft"
    end

    test "renders the given tone" do
      html =
        render_component(&CoreComponents.badge/1, %{
          tone: "success",
          inner_block: [%{inner_block: fn _, _ -> "Active" end}]
        })

      assert html =~ "badge-success"
    end
  end

  describe "empty_state/1" do
    test "renders icon, title, and description" do
      html =
        render_component(&CoreComponents.empty_state/1, %{
          icon: "hero-book-open",
          title: "No courses yet",
          description: "Once you join a cohort, it will show up here.",
          inner_block: []
        })

      assert html =~ "hero-book-open"
      assert html =~ "No courses yet"
      assert html =~ "Once you join a cohort"
    end
  end

  describe "stat/1" do
    test "renders the value and label" do
      html = render_component(&CoreComponents.stat/1, %{value: 150, label: "XP"})
      assert html =~ "150"
      assert html =~ "XP"
    end

    test "lg size uses larger typography" do
      html = render_component(&CoreComponents.stat/1, %{value: 3, label: "Level", size: "lg"})
      assert html =~ "text-3xl"
    end
  end

  describe "spinner/1" do
    test "renders a spinning arrow-path icon" do
      html = render_component(&CoreComponents.spinner/1, %{})
      assert html =~ "hero-arrow-path"
      assert html =~ "motion-safe:animate-spin"
    end
  end
end
