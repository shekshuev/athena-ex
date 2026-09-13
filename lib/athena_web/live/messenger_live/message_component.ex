defmodule AthenaWeb.MessengerLive.MessageComponent do
  @moduledoc """
  Renders a single message bubble: own vs. others' styling, "(edited)" and
  "message deleted" states, and `@mention` highlighting. A plain function
  component (no state of its own) embedded by `ThreadComponent`.
  """
  use AthenaWeb, :html
  alias Phoenix.LiveView.JS

  alias Athena.Identity

  attr :message, :map, required: true
  attr :own, :boolean, required: true
  attr :show_sender, :boolean, default: false
  attr :myself, :any, default: nil

  @doc """
  Renders one message row. The edit/view toggle is deliberately pure
  client-side `Phoenix.LiveView.JS` (both blocks are always in the DOM;
  only visibility is toggled) rather than a server-tracked "editing?"
  assign — this row lives inside a `phx-update="stream"` container, and
  stream items are only patched by explicit `stream_insert/3` calls, never
  by an ordinary reassign, so a server-driven toggle would silently not
  re-render here.
  """
  def message_bubble(assigns) do
    ~H"""
    <div class={["flex gap-2 group", @own && "flex-row-reverse"]}>
      <div class="max-w-[75%] min-w-0">
        <div :if={@show_sender && !@own} class="text-xs font-bold text-base-content/60 mb-0.5 px-1">
          {@message.account && Identity.display_name(@message.account)}
        </div>

        <div
          id={"msg-edit-#{@message.id}"}
          class="hidden rounded-2xl px-3 py-2 bg-base-100 border border-primary"
        >
          <form phx-submit={save_edit(@message.id, @myself)} phx-value-id={@message.id}>
            <textarea
              name="body"
              class="textarea textarea-ghost w-full p-0 min-h-[2.5rem] focus:outline-none"
              maxlength={Athena.Messaging.Message.max_length()}
            >{@message.body}</textarea>
            <div class="flex justify-end gap-2 mt-1">
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click={hide_edit(@message.id)}
              >
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary btn-xs">{gettext("Save")}</button>
            </div>
          </form>
        </div>

        <div
          id={"msg-view-#{@message.id}"}
          class={[
            "rounded-2xl px-3 py-2 relative",
            @own && "bg-primary text-primary-content",
            !@own && "bg-base-100 border border-base-300"
          ]}
        >
          <p :if={@message.deleted_at} class="italic opacity-60 text-sm">
            {gettext("This message was deleted")}
          </p>
          <p :if={!@message.deleted_at} class="whitespace-pre-wrap break-words text-sm">
            {highlighted_body(@message)}
          </p>
        </div>

        <div class={["flex items-center gap-2 mt-0.5 px-1", @own && "justify-end"]}>
          <span class="text-[11px] text-base-content/40">
            {Calendar.strftime(@message.inserted_at, "%H:%M")}
          </span>
          <span
            :if={@message.edited_at && !@message.deleted_at}
            class="text-[11px] text-base-content/40 italic"
          >
            {gettext("(edited)")}
          </span>
          <span
            :if={@own && !@message.deleted_at}
            id={"msg-actions-#{@message.id}"}
            class="hidden group-hover:flex items-center gap-1"
          >
            <button
              type="button"
              class="text-[11px] text-base-content/50 hover:text-primary"
              phx-click={show_edit(@message.id)}
            >
              {gettext("Edit")}
            </button>
            <button
              type="button"
              class="text-[11px] text-base-content/50 hover:text-error"
              phx-click="delete_message"
              phx-value-id={@message.id}
              phx-target={@myself}
              data-confirm={gettext("Delete this message?")}
            >
              {gettext("Delete")}
            </button>
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp save_edit(id, myself) do
    %JS{}
    |> JS.push("save_edit", target: myself)
    |> JS.hide(to: "#msg-edit-#{id}")
    |> JS.show(to: "#msg-view-#{id}")
    |> JS.show(to: "#msg-actions-#{id}", display: "flex")
  end

  defp show_edit(id) do
    %JS{}
    |> JS.hide(to: "#msg-view-#{id}")
    |> JS.hide(to: "#msg-actions-#{id}")
    |> JS.show(to: "#msg-edit-#{id}")
    |> JS.focus(to: "#msg-edit-#{id} textarea")
  end

  defp hide_edit(id) do
    %JS{}
    |> JS.hide(to: "#msg-edit-#{id}")
    |> JS.show(to: "#msg-view-#{id}")
  end

  defp highlighted_body(%{mentions: mentions, body: body})
       when is_list(mentions) and mentions != [] do
    matched_texts =
      mentions
      |> Enum.map(& &1.matched_text)
      |> Enum.uniq()
      |> Enum.sort_by(&(-String.length(&1)))

    pattern =
      matched_texts
      |> Enum.map_join("|", &Regex.escape/1)
      |> then(&"(#{&1})")
      |> Regex.compile!()

    body
    |> String.split(pattern, include_captures: true)
    |> Enum.map(fn
      chunk ->
        if chunk in matched_texts do
          Phoenix.HTML.raw(
            "<mark class=\"bg-primary/20 text-primary rounded px-0.5\">#{Phoenix.HTML.html_escape(chunk) |> Phoenix.HTML.safe_to_string()}</mark>"
          )
        else
          chunk
        end
    end)
  end

  defp highlighted_body(%{body: body}), do: body
end
