defmodule AthenaWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: AthenaWeb.Gettext
  use AthenaWeb, :verified_routes

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, default: nil, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil

  attr :kind, :atom,
    values: [:info, :error, :success, :warning],
    doc: "used for styling and flash lookup"

  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id || "flash-#{@kind}"}
      phx-click={
        JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id || "flash-#{@kind}"}")
      }
      phx-hook="FlashAutohide"
      role="alert"
      class={[
        "alert cursor-pointer w-full sm:w-96 transition-all duration-300 flex items-start bg-base-100 border",
        @kind == :info && "border-info text-info",
        @kind == :error && "border-error text-error",
        @kind == :success && "border-success text-success",
        @kind == :warning && "border-warning text-warning"
      ]}
      {@rest}
    >
      <.icon
        :if={@kind == :info}
        name="hero-information-circle-solid"
        class="h-6 w-6 shrink-0 mt-0.5 opacity-80"
      />
      <.icon
        :if={@kind == :error}
        name="hero-exclamation-circle-solid"
        class="h-6 w-6 shrink-0 mt-0.5 opacity-80"
      />
      <.icon
        :if={@kind == :success}
        name="hero-check-circle-solid"
        class="h-6 w-6 shrink-0 mt-0.5 opacity-80"
      />
      <.icon
        :if={@kind == :warning}
        name="hero-exclamation-triangle-solid"
        class="h-6 w-6 shrink-0 mt-0.5 opacity-80"
      />

      <div class="flex flex-col flex-1 gap-1">
        <p :if={@title} class="font-bold text-sm">{@title}</p>
        <p class="text-sm font-medium">{msg}</p>
      </div>

      <button
        type="button"
        class="btn btn-ghost btn-xs btn-square shrink-0 opacity-50 hover:opacity-100"
        aria-label={gettext("close")}
      >
        <.icon name="hero-x-mark-solid" class="h-4 w-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  `variant` covers the button roles actually used across the app (rather
  than every call site hand-assembling its own `btn-*` combination):
  `primary` (main CTA), `ghost` (secondary text action, e.g. "Cancel"),
  `danger` (solid destructive CTA), `danger_outline` (outlined destructive
  CTA), `warning` (outlined warning action). No variant falls back to
  `btn-outline`, same as before. `size` covers the common `btn-sm`/`btn-xs`
  cases; the default (`nil`) leaves the daisyUI default size.

  When `variant` or `size` is given, `class` is appended alongside the
  derived classes (for a one-off addition like a hover animation) rather
  than replacing them. Without either, `class` behaves as a full override,
  same as before — this keeps older call sites that pass a complete
  `class="btn ..."` string untouched.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
      <.button variant="ghost" phx-click="cancel">Cancel</.button>
      <.button variant="danger" size="sm" phx-click="delete">Delete</.button>
      <.button variant="primary" size="sm" class="group-hover:pr-3">Enter</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled form)
  attr :class, :any
  attr :variant, :string, values: ~w(primary ghost danger danger_outline warning)
  attr :size, :string, values: ~w(xs sm lg)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "btn-primary",
      "ghost" => "btn-ghost",
      "danger" => "btn-error",
      "danger_outline" => "btn-error btn-outline",
      "warning" => "btn-warning btn-outline",
      nil => "btn-outline"
    }

    sizes = %{"xs" => "btn-xs", "sm" => "btn-sm", "lg" => "btn-lg", nil => nil}

    assigns =
      if assigns[:variant] || assigns[:size] do
        assign(assigns, :class, [
          "btn",
          Map.fetch!(variants, assigns[:variant]),
          Map.fetch!(sizes, assigns[:size]),
          assigns[:class]
        ])
      else
        assign_new(assigns, :class, fn -> ["btn", Map.fetch!(variants, nil)] end)
      end

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an icon-only action button — the "edit"/"delete" cluster used in
  table rows. One shared shape instead of the half-dozen ad-hoc class
  combinations (different sizes, different hover treatments) previously
  scattered across CRUD list pages.

  `variant="primary"` is for the rare case where one icon action in a
  cluster is the primary way into the row (e.g. "open" next to plain
  "edit"/"share" icons) — everything else should stay `neutral`.

  ## Examples

      <.icon_button icon="hero-pencil-square" label="Edit" patch={~p"/admin/users/\#{user.id}/edit"} />
      <.icon_button icon="hero-trash" label="Delete" variant="danger" phx-click="delete" phx-value-id={user.id} />
  """
  attr :rest, :global,
    include: ~w(href navigate patch phx-click phx-value-id type disabled data-confirm)

  attr :variant, :string, values: ~w(neutral danger primary), default: "neutral"
  attr :size, :string, values: ~w(xs sm), default: "xs"
  attr :icon, :string, required: true

  attr :label, :string,
    required: true,
    doc: "accessible label, rendered as both aria-label and a hover title"

  attr :class, :any, default: nil

  def icon_button(%{rest: rest} = assigns) do
    variants = %{
      "neutral" => "btn-ghost",
      "danger" => "btn-ghost text-error hover:bg-error/10",
      "primary" => "btn-primary btn-soft"
    }

    assigns =
      assign(assigns, :class, [
        "btn btn-square",
        Map.fetch!(variants, assigns.variant),
        assigns.size == "xs" && "btn-xs",
        assigns.size == "sm" && "btn-sm",
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} aria-label={@label} title={@label} {@rest}>
        <.icon name={@icon} class="size-4" />
      </.link>
      """
    else
      ~H"""
      <button type="button" class={@class} aria-label={@label} title={@label} {@rest}>
        <.icon name={@icon} class="size-4" />
      </button>
      """
    end
  end

  @doc """
  Renders a colored pill — status indicators and tag/type labels alike.
  One shared shape instead of the half-dozen independently hand-rolled
  "status → color" implementations previously scattered across the app.

  ## Examples

      <.badge tone="success">Active</.badge>
      <.badge tone="error">Rejected</.badge>
  """
  attr :tone, :string,
    values: ~w(success warning error neutral info primary secondary accent),
    default: "neutral"

  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={["badge badge-sm font-bold", "badge-#{@tone}", "badge-soft", @class]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders an icon representative of a file's MIME type.

  ## Examples

      <.file_type_icon mime_type="application/pdf" class="size-6" />
  """
  attr :mime_type, :string, default: nil
  attr :class, :any, default: "size-6"

  def file_type_icon(assigns) do
    ~H"""
    <.icon name={mime_icon(@mime_type)} class={@class} />
    """
  end

  defp mime_icon("image/" <> _), do: "hero-photo"
  defp mime_icon("video/" <> _), do: "hero-film"
  defp mime_icon("audio/" <> _), do: "hero-musical-note"
  defp mime_icon("application/pdf"), do: "hero-document-text"
  defp mime_icon("text/" <> _), do: "hero-document-text"

  defp mime_icon("application/" <> rest)
       when rest in ~w(zip x-rar-compressed x-7z-compressed x-tar gzip x-gzip),
       do: "hero-archive-box"

  defp mime_icon(_), do: "hero-document"

  @doc """
  Renders a circular avatar: the given image when `src` is set, otherwise a
  colored circle with centered initials. One shared implementation instead
  of each call site hand-rolling the daisyUI placeholder markup — which
  matters here because daisyUI 5 renamed the old two-class pair
  (`avatar placeholder`) to a single `avatar-placeholder` class; the old
  pair still "works" (no error) but silently drops the centering rule,
  leaving initials stuck in the top-left corner. Going through this
  component means that can't regress at a new call site.

  ## Examples

      <.avatar initials="JD" size="w-10" text_size="text-sm" />
      <.avatar src={user.avatar_url} initials="JD" alt="Jane Doe" />
      <.avatar initials="C" color="secondary" size="w-9" text_size="text-xs" />
  """
  attr :src, :string, default: nil, doc: "avatar image URL; when nil, initials are shown instead"

  attr :initials, :string,
    default: "",
    doc: "shown when there is no `src` — keep it short (1-2 chars)"

  attr :alt, :string, default: ""
  attr :size, :string, default: "w-10", doc: "Tailwind width class, e.g. \"w-8\", \"w-14\""
  attr :text_size, :string, default: nil, doc: "Tailwind text-size class for the initials"
  attr :color, :string, values: ~w(neutral primary secondary), default: "neutral"
  attr :class, :any, default: nil, doc: "extra classes for the outer avatar element"

  def avatar(assigns) do
    colors = %{
      "neutral" => "bg-neutral text-neutral-content",
      "primary" => "bg-primary text-primary-content",
      "secondary" => "bg-secondary text-secondary-content"
    }

    assigns = assign(assigns, :color_class, Map.fetch!(colors, assigns.color))

    ~H"""
    <div class={["avatar shrink-0", @src in [nil, ""] && "avatar-placeholder", @class]}>
      <div class={["rounded-full", @size, @src in [nil, ""] && [@color_class, @text_size]]}>
        <img :if={@src not in [nil, ""]} src={@src} alt={@alt} />
        <span :if={@src in [nil, ""]} class="uppercase font-bold leading-none">{@initials}</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders a consistent "nothing here yet" placeholder — icon, title,
  optional description — replacing the several structurally different
  empty-state treatments previously used across the app. Also meant to be
  dropped in next to `<.table>` when `@rows == []`, which otherwise renders
  a silently-blank table body.

  ## Examples

      <.empty_state
        :if={@courses == []}
        icon="hero-book-open"
        title="No courses yet"
        description="Once you join a cohort, it will show up here."
      />
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class={["text-center py-16 px-6", @class]}>
      <.icon name={@icon} class="size-14 text-base-content/20 mb-4 mx-auto" />
      <h3 class="text-lg font-display font-bold text-base-content">{@title}</h3>
      <p :if={@description} class="text-base-content/60 mt-2 max-w-sm mx-auto text-sm">
        {@description}
      </p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a "number + label" metric — one shared shape instead of the
  several unrelated ad-hoc markups previously used for the same idea (an
  XP/level pill in a header, achievement numbers on a profile, mini-stat
  cards on a dashboard).

  ## Examples

      <.stat value={@total_xp} label="XP" icon="hero-star" />
      <.stat value={@level.level} label="Level" size="lg" />
  """
  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :size, :string, values: ~w(sm lg), default: "sm"
  attr :icon, :string, default: nil
  attr :class, :any, default: nil

  def stat(assigns) do
    ~H"""
    <div class={["flex flex-col", @class]}>
      <div class="flex items-center gap-1.5">
        <.icon
          :if={@icon}
          name={@icon}
          class={["text-primary shrink-0", @size == "lg" && "size-6", @size == "sm" && "size-4"]}
        />
        <span class={[
          "font-display font-black",
          @size == "lg" && "text-3xl",
          @size == "sm" && "text-lg"
        ]}>
          {@value}
        </span>
      </div>
      <span class="text-xs font-bold text-base-content/50 uppercase tracking-widest">
        {@label}
      </span>
    </div>
    """
  end

  @doc """
  Renders the outer content-width wrapper for a page — three named tiers
  instead of the five different `max-w-*` values (plus several pages with
  no limit at all) previously scattered across the app. The layout's
  `<main>` already applies consistent outer padding
  (`layouts/dashboard.html.heex`); this only controls how wide the content
  itself gets, centered via `mx-auto`.

  - `narrow` (`max-w-4xl`) — reading/single-task screens (course player,
    course overview, leaderboard, sprints).
  - `standard` (`max-w-6xl`) — the main app pages (dashboard, My Learning).
  - `wide` (`max-w-7xl`) — data-dense screens (grading, the content
    library, CRUD tables).

  Any other utility classes a page needs (vertical spacing, padding) go in
  `class`, same as before — only the width mechanism is being unified.

  ## Examples

      <.page_container size="wide" class="space-y-6 pb-20">
        ...
      </.page_container>
  """
  attr :size, :string, values: ~w(narrow standard wide), default: "standard"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def page_container(assigns) do
    sizes = %{"narrow" => "max-w-4xl", "standard" => "max-w-6xl", "wide" => "max-w-7xl"}
    assigns = assign(assigns, :size_class, Map.fetch!(sizes, assigns.size))

    ~H"""
    <div class={[@size_class, "mx-auto", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders the canonical "operation in progress" indicator — a spinning
  arrow-path icon. The one loading treatment the app should use, instead of
  mixing this with daisyUI's `loading` component or a static, non-animated
  icon that looks the same as an inert action button.

  ## Examples

      <.spinner :if={@checking?} />
  """
  attr :class, :any, default: "size-4"

  def spinner(assigns) do
    ~H"""
    <.icon name="hero-arrow-path" class={["motion-safe:animate-spin", @class]} />
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.


  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <fieldset class="fieldset mb-2 w-full">
      <label class="label cursor-pointer justify-start gap-3">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={[@class || "checkbox checkbox-primary", @errors != [] && "checkbox-error!"]}
          {@rest}
        />
        <span class="label-text font-bold">{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <fieldset class="fieldset mb-2 w-full">
      <label :if={@label} for={@id} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <select
        id={@id}
        name={@name}
        class={[
          "select w-full",
          @errors != [] && "select-error border-error!",
          @class,
          @multiple && "h-auto py-2"
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="" disabled selected={@value in [nil, ""]}>
          {@prompt}
        </option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <fieldset class="fieldset mb-2 w-full">
      <label :if={@label} for={@id} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <textarea
        id={@id}
        name={@name}
        class={[
          @class || "textarea w-full",
          @errors != [] && (@error_class || "textarea-error border-error!")
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  def input(%{type: "date"} = assigns) do
    ~H"""
    <.date_picker
      id={@id}
      name={@name}
      value={@value}
      label={@label}
      errors={@errors}
      class={@class}
      error_class={@error_class}
      min={@rest[:min]}
      max={@rest[:max]}
      placeholder={@rest[:placeholder]}
      disabled={@rest[:disabled]}
      required={@rest[:required]}
    />
    """
  end

  def input(%{type: "datetime-local"} = assigns) do
    ~H"""
    <.datetime_picker
      id={@id}
      name={@name}
      value={@value}
      label={@label}
      errors={@errors}
      class={@class}
      error_class={@error_class}
      min={@rest[:min]}
      max={@rest[:max]}
      disabled={@rest[:disabled]}
      required={@rest[:required]}
    />
    """
  end

  # All other inputs text, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <fieldset class="fieldset mb-2 w-full">
      <label :if={@label} for={@id} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          @class || "input w-full",
          @errors != [] && (@error_class || "input-error border-error!")
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  # Helper used by inputs to generate form errors
  def error(assigns) do
    ~H"""
    <p class="mt-1.5 text-error text-xs font-bold text-wrap wrap-break-word leading-tight flex gap-1 items-start">
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0 mt-0.5" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  # --- Date & time pickers ----------------------------------------------------
  #
  # `date_picker/1` and `time_picker/1` behave like `input/1` (accept `field`,
  # submit a value under `name`) and are what `input/1` renders under the hood
  # for `type="date"` / `type="datetime-local"` - the datetime-local case
  # composes both through `datetime_picker/1`.
  #
  # Values on the wire: `date_picker` submits "YYYY-MM-DD"; `time_picker`
  # submits "HH:MM"; `datetime_picker` submits the wall-clock
  # "YYYY-MM-DDTHH:MM" that `type="datetime-local"` always has - turn it into
  # UTC with `Athena.TimeZones.localize_params/2` before casting. All three
  # show `DateTime` values in the user's timezone (see `Athena.TimeZones`).

  @doc """
  A daisyUI-styled date picker: a button that opens a Cally calendar in a
  popover, with month/year jump selects and Today/Clear shortcuts. Renders
  and behaves like `<.input type="date">` (submits "YYYY-MM-DD").
  """
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:starts_on]"

  attr :errors, :list, default: []
  attr :class, :any, default: nil
  attr :error_class, :any, default: nil

  attr :embedded, :boolean,
    default: false,
    doc: "renders the control alone, with no fieldset/label/error (used by datetime_picker/1)"

  attr :min, :string, default: nil, doc: ~s(earliest selectable date, "YYYY-MM-DD")
  attr :max, :string, default: nil, doc: ~s(latest selectable date, "YYYY-MM-DD")
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false

  def date_picker(%{field: %Phoenix.HTML.FormField{}} = assigns) do
    assigns |> normalize_field_assigns() |> date_picker()
  end

  def date_picker(%{embedded: true} = assigns) do
    ~H"""
    <.date_picker_control
      id={@id || "date-picker-#{System.unique_integer([:positive])}"}
      name={@name}
      value={@value}
      class={@class}
      error_class={@error_class}
      errors={@errors}
      min={@min}
      max={@max}
      placeholder={@placeholder}
      disabled={@disabled}
    />
    """
  end

  def date_picker(assigns) do
    assigns =
      assign(assigns, :id, assigns.id || "date-picker-#{System.unique_integer([:positive])}")

    ~H"""
    <fieldset class="fieldset mb-2 w-full">
      <label :if={@label} for={"#{@id}-trigger"} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <.date_picker_control
        id={@id}
        name={@name}
        value={@value}
        class={@class}
        error_class={@error_class}
        errors={@errors}
        min={@min}
        max={@max}
        placeholder={@placeholder}
        disabled={@disabled}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  attr :id, :any, required: true
  attr :name, :any, default: nil
  attr :value, :any, default: nil
  attr :class, :any, default: nil
  attr :error_class, :any, default: nil
  attr :errors, :list, default: []
  attr :min, :string, default: nil
  attr :max, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false

  defp date_picker_control(assigns) do
    value = date_only_value(assigns.value)
    {date_part, _time_part} = split_picker_value(value)

    assigns =
      assign(assigns,
        dom_key: String.replace(assigns.id, ~r/[^A-Za-z0-9_-]/, "-"),
        value: value,
        date_part: date_part,
        min: date_bound(assigns.min),
        max: date_bound(assigns.max),
        placeholder: assigns.placeholder || gettext("Pick a date"),
        locale: Gettext.get_locale(AthenaWeb.Gettext)
      )

    ~H"""
    <div id={"#{@id}-picker"} phx-hook=".DatePicker" class="flex-1 min-w-0">
      <input
        type="hidden"
        id={@id}
        name={@name}
        value={@value}
        data-role="date-value"
        disabled={@disabled}
      />

      <button
        type="button"
        id={"#{@id}-trigger"}
        popovertarget={"#{@dom_key}-popover"}
        disabled={@disabled}
        style={"anchor-name: --#{@dom_key}"}
        class={[
          @class || "input w-full",
          "justify-start gap-2 cursor-pointer text-left",
          @errors != [] && (@error_class || "input-error border-error!")
        ]}
      >
        <.icon name="hero-calendar-days" class="size-4 shrink-0 text-base-content/40" />
        <span
          data-role="label"
          data-placeholder={@placeholder}
          class={["truncate", @date_part == "" && "text-base-content/40"]}
        >
          {if @date_part == "", do: @placeholder, else: display_date(@date_part)}
        </span>
      </button>

      <div
        popover
        id={"#{@dom_key}-popover"}
        style={"position-anchor: --#{@dom_key}"}
        class="dropdown bg-base-100 rounded-sm border border-base-300 p-3 mt-2"
      >
        <div class="flex gap-2 mb-2">
          <select data-role="month" aria-label={gettext("Month")} class="select select-sm flex-1">
            <option :for={{name, m} <- month_options()} value={m}>{name}</option>
          </select>
          <select data-role="year" aria-label={gettext("Year")} class="select select-sm w-24">
            <option :for={y <- year_options(@min, @max)} value={y}>{y}</option>
          </select>
        </div>

        <calendar-date
          class="cally"
          value={@date_part}
          min={@min}
          max={@max}
          locale={@locale}
          first-day-of-week="1"
          data-role="calendar"
        >
          <svg
            aria-label={gettext("Previous")}
            class="fill-current size-4"
            slot="previous"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="M15.75 19.5 8.25 12l7.5-7.5"></path>
          </svg>
          <svg
            aria-label={gettext("Next")}
            class="fill-current size-4"
            slot="next"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="m8.25 4.5 7.5 7.5-7.5 7.5"></path>
          </svg>
          <calendar-month></calendar-month>
        </calendar-date>

        <div class="flex justify-between gap-2 mt-2 pt-2 border-t border-base-200">
          <button type="button" data-role="today" class="btn btn-ghost btn-xs">
            {gettext("Today")}
          </button>
          <button type="button" data-role="clear" class="btn btn-ghost btn-xs text-base-content/60">
            {gettext("Clear")}
          </button>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DatePicker">
      const pad = (n) => String(n).padStart(2, "0");
      const isoDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
      const displayDate = (iso) => {
        const [y, m, d] = iso.split("-");
        return `${d}.${m}.${y}`;
      };

      export default {
        mounted() {
          this.q = (role) => this.el.querySelector(`[data-role="${role}"]`);

          const calendar = this.q("calendar");
          const popover = calendar.closest("[popover]");

          calendar.addEventListener("change", () => {
            this.setDate(calendar.value);
            popover.hidePopover();
          });
          // Keep the month/year selects in sync with the month Cally shows.
          calendar.addEventListener("focusday", (e) => this.syncSelects(e.detail));
          popover.addEventListener("toggle", (e) => {
            if (e.newState === "open") this.syncSelects(calendar.value || isoDate(new Date()));
          });

          const jump = () => {
            calendar.focusedDate = `${this.q("year").value}-${pad(this.q("month").value)}-01`;
          };
          this.q("month").addEventListener("change", (e) => { e.stopPropagation(); jump(); });
          this.q("year").addEventListener("change", (e) => { e.stopPropagation(); jump(); });
          ["input", "change"].forEach((type) => {
            this.q("month").addEventListener(type, (e) => e.stopPropagation());
            this.q("year").addEventListener(type, (e) => e.stopPropagation());
          });

          this.q("today").addEventListener("click", () => {
            this.setDate(isoDate(new Date()));
            popover.hidePopover();
          });
          this.q("clear").addEventListener("click", () => {
            this.setDate("");
            popover.hidePopover();
          });
        },

        syncSelects(value) {
          if (!value) return;
          const [y, m] = String(value).split("-");
          const year = this.q("year");
          if (![...year.options].some((o) => o.value === y)) year.add(new Option(y, y));
          year.value = y;
          this.q("month").value = String(Number(m));
        },

        setDate(iso) {
          this.q("calendar").value = iso;
          const label = this.q("label");
          label.textContent = iso ? displayDate(iso) : label.dataset.placeholder;
          label.classList.toggle("text-base-content/40", !iso);

          const hidden = this.q("date-value");
          if (hidden.value === iso) return;
          hidden.value = iso;
          hidden.dispatchEvent(new Event("input", { bubbles: true }));
        },
      };
    </script>
    """
  end

  @doc """
  A masked 24-hour time field ("--:--", digits only, clamped to valid
  hours/minutes as you type - "5" alone becomes "05" and jumps to minutes).
  Renders and behaves like `<.input type="time">` (submits "HH:MM").
  """
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:opens_at]"

  attr :errors, :list, default: []
  attr :class, :any, default: nil
  attr :error_class, :any, default: nil

  attr :embedded, :boolean,
    default: false,
    doc: "renders the control alone, with no fieldset/label/error (used by datetime_picker/1)"

  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false

  def time_picker(%{field: %Phoenix.HTML.FormField{}} = assigns) do
    assigns |> normalize_field_assigns() |> time_picker()
  end

  def time_picker(%{embedded: true} = assigns) do
    ~H"""
    <.time_picker_control
      id={@id || "time-picker-#{System.unique_integer([:positive])}"}
      name={@name}
      value={@value}
      class={@class}
      error_class={@error_class}
      errors={@errors}
      disabled={@disabled}
    />
    """
  end

  def time_picker(assigns) do
    assigns =
      assign(assigns, :id, assigns.id || "time-picker-#{System.unique_integer([:positive])}")

    ~H"""
    <fieldset class="fieldset mb-2 w-full">
      <label :if={@label} for={@id} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <.time_picker_control
        id={@id}
        name={@name}
        value={@value}
        class={@class}
        error_class={@error_class}
        errors={@errors}
        disabled={@disabled}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  attr :id, :any, required: true
  attr :name, :any, default: nil
  attr :value, :any, default: nil
  attr :class, :any, default: nil
  attr :error_class, :any, default: nil
  attr :errors, :list, default: []
  attr :disabled, :boolean, default: false

  defp time_picker_control(assigns) do
    assigns = assign(assigns, value: time_only_value(assigns.value))

    ~H"""
    <div class="w-28 shrink-0">
      <label class={[
        @class || "input w-full gap-2 tabular-nums",
        @errors != [] && (@error_class || "input-error border-error!")
      ]}>
        <.icon name="hero-clock" class="size-4 shrink-0 text-base-content/40" />
        <input
          type="text"
          inputmode="numeric"
          autocomplete="off"
          id={@id}
          name={@name}
          phx-hook=".TimePicker"
          value={@value}
          placeholder="--:--"
          aria-label={gettext("Time")}
          disabled={@disabled}
          data-role="time-value"
          class="grow min-w-0 font-mono tracking-widest"
        />
      </label>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TimePicker">
      const PLACEHOLDER = "_";
      const blank = () => [PLACEHOLDER, PLACEHOLDER, PLACEHOLDER, PLACEHOLDER];

      export default {
        mounted() {
          // Exposed so .DateTimePicker can read/drive this field without
          // guessing at its formatted string (see core_components.ex).
          this.el.__timePicker = this;
          this.syncFromValue(this.el.value);

          this.el.addEventListener("keydown", (e) => this.handleKeydown(e));
          this.el.addEventListener("paste", (e) => this.handlePaste(e));
          this.el.addEventListener("blur", () => this.handleBlur());
        },

        isEmpty() {
          return this.pos === 0;
        },

        isComplete() {
          return this.pos === 4;
        },

        // Sets a complete value (e.g. defaulting to "00:00" once a date is
        // picked) while keeping our digit state in sync.
        setValue(value) {
          this.syncFromValue(value);
          this.commit();
        },

        syncFromValue(value) {
          const match = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(value || "");
          if (match) {
            this.digits = [...match[1], ...match[2]];
            this.pos = 4;
          } else {
            this.digits = blank();
            this.pos = 0;
          }
          this.render();
        },

        handleKeydown(e) {
          if (e.key === "Tab" || e.key === "Escape" || e.key === "Enter") return;
          if ((e.metaKey || e.ctrlKey) && ["a", "c", "v", "x"].includes(e.key.toLowerCase())) return;

          e.preventDefault();

          if (e.key === "Backspace") {
            this.pos = Math.max(this.pos - 1, 0);
            this.digits[this.pos] = PLACEHOLDER;
            this.render();
            this.commit();
          } else if (e.key === "Delete") {
            this.digits = blank();
            this.pos = 0;
            this.render();
            this.commit();
          } else if (/^[0-9]$/.test(e.key)) {
            this.typeDigit(Number(e.key));
          }
        },

        handlePaste(e) {
          e.preventDefault();
          const text = (e.clipboardData || window.clipboardData).getData("text");
          this.digits = blank();
          this.pos = 0;
          for (const digit of text.replace(/\D/g, "").slice(0, 4)) this.typeDigit(Number(digit));
        },

        handleBlur() {
          // Only a complete "HH:MM" is a valid value - anything half-typed reverts to empty.
          if (this.pos > 0 && this.pos < 4) {
            this.digits = blank();
            this.pos = 0;
            this.render();
            this.commit();
          }
        },

        // Digit-by-digit entry with range clamping, so e.g. "5" alone becomes
        // "05" and jumps straight to minutes instead of waiting for an
        // impossible second digit.
        typeDigit(d) {
          if (this.pos === 4) {
            this.digits = blank();
            this.pos = 0;
          }

          if (this.pos === 0) {
            if (d > 2) {
              this.digits[0] = "0";
              this.digits[1] = String(d);
              this.pos = 2;
            } else {
              this.digits[0] = String(d);
              this.pos = 1;
            }
          } else if (this.pos === 1) {
            const maxOnes = this.digits[0] === "2" ? 3 : 9;
            this.digits[1] = String(Math.min(d, maxOnes));
            this.pos = 2;
          } else if (this.pos === 2) {
            if (d > 5) {
              this.digits[2] = "0";
              this.digits[3] = String(d);
              this.pos = 4;
            } else {
              this.digits[2] = String(d);
              this.pos = 3;
            }
          } else {
            this.digits[3] = String(d);
            this.pos = 4;
          }

          this.render();
          this.commit();
        },

        render() {
          this.el.value = `${this.digits[0]}${this.digits[1]}:${this.digits[2]}${this.digits[3]}`;
        },

        commit() {
          this.el.dispatchEvent(new Event("input", { bubbles: true }));
        },
      };
    </script>
    """
  end

  @doc """
  Composes `date_picker/1` and `time_picker/1` into one field that submits
  the wall-clock "YYYY-MM-DDTHH:MM" that `<.input type="datetime-local">`
  submits. Picking a date defaults the time to 00:00; clearing the date
  clears the time.
  """
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:starts_at]"

  attr :errors, :list, default: []
  attr :class, :any, default: nil
  attr :error_class, :any, default: nil
  attr :min, :string, default: nil
  attr :max, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false

  def datetime_picker(%{field: %Phoenix.HTML.FormField{}} = assigns) do
    assigns |> normalize_field_assigns() |> datetime_picker()
  end

  def datetime_picker(assigns) do
    value = Athena.TimeZones.input_value(assigns.value)
    {date_part, time_part} = split_picker_value(value)
    id = assigns.id || "datetime-picker-#{System.unique_integer([:positive])}"

    assigns =
      assign(assigns,
        id: id,
        value: value,
        date_part: date_part,
        time_part: time_part,
        min: date_bound(assigns.min),
        max: date_bound(assigns.max)
      )

    ~H"""
    <fieldset class="fieldset mb-2 w-full">
      <label :if={@label} for={"#{@id}-date-trigger"} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <div id={"#{@id}-wrap"} phx-hook=".DateTimePicker" class="flex gap-2">
        <input type="hidden" id={@id} name={@name} value={@value} data-role="value" />

        <.date_picker_control
          id={"#{@id}-date"}
          value={@date_part}
          class={@class}
          error_class={@error_class}
          errors={@errors}
          min={@min}
          max={@max}
          disabled={@disabled}
        />
        <.time_picker_control
          id={"#{@id}-time"}
          value={@time_part}
          class={@class}
          error_class={@error_class}
          errors={@errors}
          disabled={@disabled}
        />
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DateTimePicker">
      export default {
        mounted() {
          this.dateEl = this.el.querySelector('[data-role="date-value"]');
          this.timeEl = this.el.querySelector('[data-role="time-value"]');
          this.hidden = this.el.querySelector('[data-role="value"]');

          this.el.addEventListener("input", (e) => {
            if (e.target !== this.hidden) this.commit();
          });
        },

        commit() {
          const date = this.dateEl.value || "";
          const time = this.timeEl.__timePicker;

          if (!date) {
            if (time && !time.isEmpty()) time.setValue("");
          } else if (time && time.isEmpty()) {
            time.setValue("00:00");
          }

          const timeValue = time && time.isComplete() ? this.timeEl.value : "00:00";
          const value = date ? `${date}T${timeValue}` : "";

          if (this.hidden.value === value) return;
          this.hidden.value = value;
          this.hidden.dispatchEvent(new Event("input", { bubbles: true }));
        },
      };
    </script>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :meta, Flop.Meta, default: nil, doc: "Flop meta for sorting"
  attr :path_fn, :any, default: nil, doc: "Function that takes a map of params and returns a URL"
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :sort, :string, doc: "Field name for Flop sorting"
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto overflow-y-visible border border-base-300 rounded-sm">
      <table class="table table-zebra table-sm">
        <thead>
          <tr>
            <th :for={col <- @col}>
              <%= if col[:sort] && @meta && @path_fn do %>
                <% current_sort? = Enum.map(@meta.flop.order_by || [], &to_string/1) == [col[:sort]] %>
                <% direction =
                  if current_sort? and
                       Enum.map(@meta.flop.order_directions || [], &to_string/1) == ["asc"],
                     do: "desc",
                     else: "asc" %>
                <.link
                  patch={@path_fn.(%{"order_by" => [col[:sort]], "order_directions" => [direction]})}
                  class="flex items-center gap-1 hover:text-primary transition-colors group select-none"
                >
                  {col[:label]}
                  <.icon
                    :if={current_sort? && direction == "desc"}
                    name="hero-chevron-up"
                    class="size-4"
                  />
                  <.icon
                    :if={current_sort? && direction == "asc"}
                    name="hero-chevron-down"
                    class="size-4"
                  />
                  <.icon
                    :if={!current_sort?}
                    name="hero-chevron-up-down"
                    class="size-4 opacity-0 group-hover:opacity-50 transition-opacity"
                  />
                </.link>
              <% else %>
                {col[:label]}
              <% end %>
            </th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={@row_click && "hover:cursor-pointer"}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 font-semibold">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list bg-base-200 border border-base-300 rounded-sm">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(AthenaWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AthenaWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders a placeholder for work-in-progress pages.
  """
  attr :title, :string, default: "Work in Progress"

  attr :description, :string,
    default: "This feature is currently under active development. Stay tuned for updates."

  attr :icon, :string, default: "hero-hammer"

  def placeholder(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center flex-1 min-h-[60vh] p-8 text-center animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div class="relative mb-8 group">
        <div class="relative flex items-center justify-center w-24 h-24 rounded-sm bg-base-200 border border-base-300">
          <.icon
            name={@icon}
            class="w-12 h-12 text-primary group-hover:scale-110 transition-transform duration-300"
          />
        </div>
      </div>

      <h3 class="text-3xl font-display font-black uppercase tracking-tight text-base-content mb-3">
        {@title}
      </h3>
      <p class="text-base-content/60 max-w-md mx-auto mb-10 leading-relaxed font-medium">
        {@description}
      </p>

      <div class="flex flex-wrap justify-center gap-4">
        <button
          type="button"
          onclick="history.back()"
          class="btn btn-outline font-bold uppercase"
        >
          <.icon name="hero-arrow-left" class="size-5" />
          {gettext("Go Back")}
        </button>

        <.link
          navigate={~p"/dashboard"}
          class="btn btn-primary font-bold uppercase px-8"
        >
          <.icon name="hero-squares-2x2" class="size-5" />
          {gettext("Dashboard")}
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  Renders a DaisyUI modal dynamically using LiveView state.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :on_cancel, JS, default: %JS{}
  attr :on_confirm, JS, default: nil
  attr :confirm_label, :string, default: "Confirm"
  attr :danger, :boolean, default: false
  slot :inner_block

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={["modal", @show && "modal-open"]}
      phx-window-keydown={@show && @on_cancel}
      phx-key="escape"
    >
      <div class="modal-box rounded-sm border border-base-300">
        <h3 :if={@title} class="font-bold text-lg">{@title}</h3>
        <p :if={@description} class="py-4 text-base-content/70">{@description}</p>

        {render_slot(@inner_block)}

        <div :if={@on_confirm} class="modal-action">
          <button
            type="button"
            class="btn btn-outline btn-sm"
            phx-click={@on_cancel}
          >
            {gettext("Cancel")}
          </button>

          <button
            type="button"
            class={["btn btn-sm", @danger && "btn-error", !@danger && "btn-primary"]}
            phx-click={@on_confirm}
          >
            {@confirm_label}
          </button>
        </div>
      </div>

      <div class="modal-backdrop bg-black/50" phx-click={@on_cancel}>
        <button type="button" class="cursor-default" aria-label={gettext("close")}></button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a slide-over (drawer) for forms.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :title, :string, required: true
  attr :on_close, JS, required: true
  slot :inner_block, required: true

  def slide_over(assigns) do
    ~H"""
    <div
      class={["drawer drawer-end absolute inset-0 z-100", !@show && "hidden"]}
      style="pointer-events: none;"
    >
      <input
        id={"#{@id}-toggle"}
        type="checkbox"
        class="drawer-toggle"
        checked={@show}
        aria-hidden="true"
      />
      <div class="drawer-side" style="pointer-events: auto;">
        <label for={"#{@id}-toggle"} class="drawer-overlay" phx-click={@on_close}></label>
        <div class="bg-base-100 text-base-content min-h-full w-full max-w-md p-0 flex flex-col border-l border-base-300">
          <div class="p-6 border-b border-base-300 flex items-center justify-between shrink-0">
            <h2 class="text-xl font-display font-bold">{@title}</h2>
            <button type="button" class="btn btn-ghost btn-square btn-sm" phx-click={@on_close}>
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <div class="flex-1 overflow-y-auto p-6">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders pagination and page size selector using Flop.Meta.
  """
  attr :meta, Flop.Meta, required: true

  attr :path_fn, :any,
    required: true,
    doc: "Function that takes a map of params and returns a URL"

  def pagination(assigns) do
    ~H"""
    <div class="flex flex-col sm:flex-row items-center justify-between w-full gap-4 mt-4">
      <div class="flex items-center gap-2">
        <span class="text-sm text-base-content/60">{gettext("Show")}</span>
        <form phx-change="update_page_size">
          <select name="page_size" class="select select-sm">
            <%= for size <- [10, 20, 50, 100] do %>
              <option value={size} selected={@meta.page_size == size}>{size}</option>
            <% end %>
          </select>
        </form>
      </div>

      <div :if={@meta.total_pages > 1} class="join">
        <.link
          patch={@path_fn.(%{"page" => @meta.current_page - 1})}
          class={[
            "join-item btn btn-sm btn-outline",
            @meta.current_page <= 1 && "pointer-events-none opacity-50"
          ]}
          tabindex={if @meta.current_page <= 1, do: -1, else: 0}
        >
          «
        </.link>
        <button class="join-item btn btn-sm pointer-events-none btn-outline">
          {gettext("Page %{current} of %{total}",
            current: @meta.current_page,
            total: @meta.total_pages
          )}
        </button>
        <.link
          patch={@path_fn.(%{"page" => @meta.current_page + 1})}
          class={[
            "join-item btn btn-sm btn-outline",
            @meta.current_page >= @meta.total_pages && "pointer-events-none opacity-50"
          ]}
          tabindex={if @meta.current_page >= @meta.total_pages, do: -1, else: 0}
        >
          »
        </.link>
      </div>
    </div>
    """
  end

  @commit_sha (if sha = System.get_env("COMMIT_SHA") do
                 String.slice(sha, 0, 7)
               else
                 case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
                   {sha, 0} -> String.trim(sha)
                   _ -> "dev"
                 end
               end)

  # Docker builds have no .git dir, so this comes from the APP_VERSION
  # build-arg (set to the pushed tag, e.g. "v0.16.0" — see release.yml).
  # Outside Docker (dev/test), it falls back to the local tag history.
  @app_version (if version = System.get_env("APP_VERSION") do
                  String.trim(version)
                else
                  case System.cmd("git", ["describe", "--tags", "--always"],
                         stderr_to_stdout: true
                       ) do
                    {out, 0} -> String.trim(out)
                    _ -> "dev"
                  end
                end)

  def app_version do
    "#{@app_version} (#{@commit_sha})"
  end

  # --- date/time picker helpers -----------------------------------------------

  defp normalize_field_assigns(%{field: field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
  end

  defp date_only_value(%Date{} = date), do: Date.to_iso8601(date)

  defp date_only_value(%DateTime{} = dt),
    do: dt |> Athena.TimeZones.to_local() |> DateTime.to_date() |> Date.to_iso8601()

  defp date_only_value(value) when is_binary(value), do: String.slice(value, 0, 10)
  defp date_only_value(_value), do: ""

  defp time_only_value(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  defp time_only_value(value) when is_binary(value) and byte_size(value) >= 5,
    do: String.slice(value, 0, 5)

  defp time_only_value(_value), do: ""

  defp split_picker_value(<<date::binary-size(10), "T", time::binary-size(5), _::binary>>),
    do: {date, time}

  defp split_picker_value(<<date::binary-size(10), _::binary>>), do: {date, ""}
  defp split_picker_value(_), do: {"", ""}

  defp display_date(<<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2)>>),
    do: "#{d}.#{m}.#{y}"

  defp display_date(other), do: other

  defp date_bound(nil), do: nil
  defp date_bound(%Date{} = date), do: Date.to_iso8601(date)
  defp date_bound(value) when is_binary(value), do: String.slice(value, 0, 10)
  defp date_bound(_), do: nil

  defp month_options do
    [
      gettext("January"),
      gettext("February"),
      gettext("March"),
      gettext("April"),
      gettext("May"),
      gettext("June"),
      gettext("July"),
      gettext("August"),
      gettext("September"),
      gettext("October"),
      gettext("November"),
      gettext("December")
    ]
    |> Enum.with_index(1)
  end

  # Year dropdown: bounded by min/max when given, otherwise wide enough for
  # both birth dates and scheduling.
  defp year_options(min, max) do
    current = Date.utc_today().year
    from = year_of(min) || current - 100
    to = year_of(max) || current + 10
    Enum.to_list(to..from//-1)
  end

  defp year_of(<<y::binary-size(4), _::binary>>) do
    case Integer.parse(y) do
      {year, ""} -> year
      _ -> nil
    end
  end

  defp year_of(_), do: nil
end
