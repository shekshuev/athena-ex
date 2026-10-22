defmodule AthenaWeb.PermalinkLive do
  @moduledoc """
  Resolves a shareable `/go/blocks/:id` or `/go/sections/:id` link into
  wherever the current viewer should land - the Builder (editor) or the
  Player (enrolled student) - or a plain "not found"/"access denied" page.

  All the actual authorization/unlock logic lives in
  `Athena.Content.Permalinks`; this LiveView only turns its answer into a
  real path, since building one (route helpers, `~p`) needs `AthenaWeb`,
  which the `Athena` context boundary may not depend on.
  """
  use AthenaWeb, :live_view

  alias Athena.Content
  alias AthenaWeb.StudioLive.Builder

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    result =
      case socket.assigns.live_action do
        :block -> Content.resolve_block_permalink(user, id)
        :section -> Content.resolve_section_permalink(user, id)
      end

    case result do
      {:ok, kind, course, section, block_id} ->
        {:ok, push_navigate(socket, to: target_path(kind, course, section, block_id))}

      {:error, reason} ->
        {:ok, assign(socket, :error, reason)}
    end
  end

  defp target_path(:builder, course, section, nil),
    do: Builder.builder_section_path(course, section.id)

  defp target_path(:builder, course, section, block_id),
    do: Builder.builder_block_path(course, section.id, block_id)

  defp target_path(:player, course, section, nil),
    do: ~p"/learn/courses/#{course.id}/play/#{section.id}"

  defp target_path(:player, course, section, block_id),
    do: ~p"/learn/courses/#{course.id}/play/#{section.id}?block=#{block_id}"

  @impl true
  def render(%{error: :not_found} = assigns) do
    ~H"""
    <.error_screen
      icon="hero-magnifying-glass"
      title={gettext("Not found")}
      message={gettext("This link doesn't point to anything you can see right now.")}
    />
    """
  end

  def render(%{error: :forbidden} = assigns) do
    ~H"""
    <.error_screen
      icon="hero-lock-closed"
      title={gettext("Access denied")}
      message={gettext("You don't have access to this course.")}
    />
    """
  end

  def render(assigns), do: ~H""

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :message, :string, required: true

  defp error_screen(assigns) do
    ~H"""
    <.page_container
      size="narrow"
      class="flex flex-col items-center justify-center text-center py-24 gap-3"
    >
      <.icon name={@icon} class="size-12 text-base-content/30" />
      <h1 class="text-xl font-black font-display">{@title}</h1>
      <p class="text-base-content/60 max-w-sm">{@message}</p>
      <.link navigate={~p"/dashboard"} class="btn btn-primary btn-sm mt-2">
        {gettext("Go to dashboard")}
      </.link>
    </.page_container>
    """
  end
end
