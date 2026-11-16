defmodule AthenaWeb.Hooks.Readonly do
  @moduledoc "Checks persisted interaction policy before student actions, including stale tabs."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView
  use Gettext, backend: AthenaWeb.Gettext

  alias Athena.Content.InteractionPolicy

  @read_events ~w(open_course_map close_course_map open_leaderboard close_leaderboard cancel_media_upload engagement_batch engagement_heartbeat)

  def on_mount(mode, _params, _session, socket) do
    {:cont,
     socket
     |> attach_hook(:readonly_actions, :handle_event, &check_event(mode, &1, &2, &3))
     |> attach_hook(:readonly_uploads, :handle_info, &check_upload(mode, &1, &2))}
  end

  defp check_upload(
         mode,
         {AthenaWeb.StudioLive.MediaUploadComponent, {:saved, block_id, _, _}},
         socket
       ) do
    id = block_id(mode, %{"block_id" => block_id}, socket.assigns)

    if InteractionPolicy.block_readonly?(id) do
      {:halt, socket |> assign(:show_media_modal, false) |> assign(:active_upload_block_id, nil)}
    else
      {:cont, socket}
    end
  end

  defp check_upload(_mode, _message, socket), do: {:cont, socket}

  defp check_event(_mode, event, _params, socket) when event in @read_events,
    do: {:cont, socket}

  defp check_event(mode, event, params, socket) do
    id = action_block_id(mode, event, params, socket.assigns)

    if InteractionPolicy.block_readonly?(id) do
      {:halt, put_flash(socket, :info, gettext("This block is read-only."))}
    else
      {:cont, socket}
    end
  end

  defp block_id(:assessment, _params, assigns), do: assigns.block.id

  defp block_id(:player, params, assigns) do
    params["block_id"] || assigns[:active_upload_block_id]
  end

  # Use precisely the identifier that the event handler consumes. Extra,
  # conflicting client parameters must never authorize a different block.
  defp action_block_id(:player, "complete_gate", params, _assigns), do: params["block-id"]
  defp action_block_id(:player, "update_content", params, _assigns), do: params["id"]

  defp action_block_id(:player, "reorder_matching_answer", params, _assigns),
    do: params["blockId"]

  defp action_block_id(:player, "media_upload_clipboard_request", _params, assigns),
    do: assigns[:active_upload_block_id]

  defp action_block_id(:player, "survey_answer", params, assigns),
    do: survey_block_id(params["question_id"], assigns)

  defp action_block_id(:player, "survey_rank", params, assigns),
    do: survey_block_id(params["questionId"], assigns)

  defp action_block_id(mode, _event, params, assigns), do: block_id(mode, params, assigns)

  defp survey_block_id(question_id, assigns) do
    Enum.find_value(assigns[:survey_state] || %{}, fn {id, state} ->
      if survey_question?(state, question_id), do: id
    end)
  end

  defp survey_question?(%{flow: flow}, id), do: not is_nil(Athena.Surveys.Flow.question(flow, id))
  defp survey_question?(_state, _id), do: false
end
