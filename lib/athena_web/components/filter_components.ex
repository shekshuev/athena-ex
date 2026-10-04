defmodule AthenaWeb.FilterComponents do
  @moduledoc """
  Shared pieces for filterable lists.

  `active_filters/1` shows every filter currently narrowing a list as a chip
  ("Status: Needs review ×"), each clearable on its own, plus a "Reset all".
  The page owns the filter state: it builds the list of active filters and
  handles the clear events (`phx-value-key` names the filter to drop).

      <.active_filters
        id="grading-active-filters"
        filters={[%{key: "status", label: gettext("Status"), value: "Needs review"}]}
      />

      def handle_event("clear_filter", %{"key" => key}, socket), do: ...
      def handle_event("reset_filters", _params, socket), do: ...
  """
  use Phoenix.Component
  use Gettext, backend: AthenaWeb.Gettext

  import AthenaWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true

  attr :filters, :list,
    required: true,
    doc: "active filters, each `%{key: String.t(), label: String.t(), value: String.t()}`"

  attr :clear_event, :string, default: "clear_filter", doc: "event sent with `key` to clear one"
  attr :clear_all_event, :string, default: "reset_filters"
  attr :class, :any, default: nil

  def active_filters(assigns) do
    ~H"""
    <div
      :if={@filters != []}
      id={@id}
      class={["flex flex-wrap items-center gap-2", @class]}
      aria-label={gettext("Active filters")}
    >
      <span
        :for={filter <- @filters}
        id={"#{@id}-#{filter.key}"}
        class="inline-flex items-center gap-1.5 rounded-full border border-primary/20 bg-primary/5 pl-3 pr-1 py-0.5 text-sm"
      >
        <span class="text-base-content/60">{filter.label}:</span>
        <span class="font-bold max-w-56 truncate" title={filter.value}>{filter.value}</span>
        <button
          type="button"
          phx-click={@clear_event}
          phx-value-key={filter.key}
          class="btn btn-ghost btn-circle btn-xs size-5 min-h-0 text-base-content/50 hover:text-error hover:bg-error/10 transition-colors"
          aria-label={gettext("Clear filter: %{label}", label: filter.label)}
          title={gettext("Clear filter: %{label}", label: filter.label)}
        >
          <.icon name="hero-x-mark-mini" class="size-3.5" />
        </button>
      </span>
      <button
        :if={length(@filters) > 1}
        type="button"
        phx-click={@clear_all_event}
        class="btn btn-ghost btn-xs text-base-content/60 hover:text-error transition-colors"
      >
        <.icon name="hero-arrow-path" class="size-3" />
        {gettext("Reset all")}
      </button>
    </div>
    """
  end
end
