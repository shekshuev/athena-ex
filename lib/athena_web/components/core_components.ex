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
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
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
      role="alert"
      class={[
        "alert shadow-none border cursor-pointer w-full sm:w-96 transition-all duration-300 flex items-start",
        @kind == :info && "alert-info text-info-content",
        @kind == :error && "alert-error text-error-content"
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

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled form)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

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

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

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
    <div class="form-control mb-2 w-full">
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
          class={[@class || "checkbox checkbox-primary", @errors != [] && "border-error"]}
          {@rest}
        />
        <span class="label-text font-bold">{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="form-control mb-2 w-full">
      <label :if={@label} for={@id} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <select
        id={@id}
        name={@name}
        class={[
          "select select-bordered w-full",
          @errors != [] && "select-error",
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
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="form-control mb-2 w-full">
      <label :if={@label} for={@id} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <textarea
        id={@id}
        name={@name}
        class={[
          @class || "textarea textarea-bordered w-full",
          @errors != [] && (@error_class || "textarea-error border-error")
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="form-control mb-2 w-full">
      <label :if={@label} for={@id} class="label">
        <span class="label-text font-bold">{@label}</span>
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          @class || "input input-bordered w-full",
          @errors != [] && (@error_class || "input-error border-error")
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
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
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
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
    <ul class="list">
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
        <div class="absolute inset-0 bg-primary/20 blur-3xl rounded-full opacity-50 group-hover:opacity-100 transition-opacity duration-700" />

        <div class="relative flex items-center justify-center w-24 h-24 rounded-2xl bg-base-100 ring-1 ring-base-300 shadow-xl border border-base-200">
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
          class="btn btn-ghost font-bold uppercase"
        >
          <.icon name="hero-arrow-left" class="size-5" />
          {gettext("Go Back")}
        </button>

        <.link
          navigate={~p"/dashboard"}
          class="btn btn-primary btn-soft font-bold uppercase px-8"
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
      <div class="modal-box">
        <h3 :if={@title} class="font-bold text-lg">{@title}</h3>
        <p :if={@description} class="py-4 text-base-content/70">{@description}</p>

        {render_slot(@inner_block)}

        <div :if={@on_confirm} class="modal-action">
          <button
            type="button"
            class="btn btn-ghost"
            phx-click={@on_cancel}
          >
            {gettext("Cancel")}
          </button>

          <button
            type="button"
            class={["btn", @danger && "btn-error", !@danger && "btn-primary"]}
            phx-click={@on_confirm}
          >
            {@confirm_label}
          </button>
        </div>
      </div>

      <div class="modal-backdrop" phx-click={@on_cancel}>
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
        <div class="menu bg-base-100 text-base-content min-h-full w-full max-w-md p-0 flex flex-col shadow-2xl">
          <div class="p-6 border-b border-base-300 flex items-center justify-between shrink-0">
            <h2 class="text-xl font-display font-bold">{@title}</h2>
            <button type="button" class="btn btn-ghost btn-circle btn-sm" phx-click={@on_close}>
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
  Renders pagination using Flop.Meta.
  """
  attr :meta, Flop.Meta, required: true
  attr :path_fn, :any, required: true, doc: "Function that takes a page number and returns a URL"

  def pagination(assigns) do
    ~H"""
    <div :if={@meta.total_pages > 1} class="join">
      <.link
        patch={@path_fn.(@meta.current_page - 1)}
        class={["join-item btn btn-sm", @meta.current_page <= 1 && "pointer-events-none opacity-50"]}
        tabindex={if @meta.current_page <= 1, do: -1, else: 0}
      >
        «
      </.link>
      <button class="join-item btn btn-sm pointer-events-none">
        {gettext("Page %{current} of %{total}", current: @meta.current_page, total: @meta.total_pages)}
      </button>
      <.link
        patch={@path_fn.(@meta.current_page + 1)}
        class={[
          "join-item btn btn-sm",
          @meta.current_page >= @meta.total_pages && "pointer-events-none opacity-50"
        ]}
        tabindex={if @meta.current_page >= @meta.total_pages, do: -1, else: 0}
      >
        »
      </.link>
    </div>
    """
  end

  @commit_sha (case System.cmd("git", ["rev-parse", "--short", "HEAD"]) do
                 {sha, 0} -> String.trim(sha)
                 _ -> "dev"
               end)

  def app_version do
    vsn = Application.spec(:athena, :vsn) |> to_string()
    "v#{vsn} (#{@commit_sha})"
  end
end
