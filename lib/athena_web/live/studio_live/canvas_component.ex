defmodule AthenaWeb.StudioLive.Builder.CanvasComponent do
  @moduledoc """
  LiveComponent for rendering the main canvas with blocks.
  Uses universal content_block for rendering, and overlays contextual editors 
  when a block is selected.
  """
  use AthenaWeb, :live_component
  import AthenaWeb.BlockComponents

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col relative">
      <div :if={@active_section_id == nil} class="flex-1 flex items-center justify-center">
        <p class="text-base-content/50 font-medium">
          {gettext("Select a section from the sidebar to view its blocks.")}
        </p>
      </div>

      <div :if={@active_section_id != nil} class="flex-1 flex flex-col">
        <div
          id="canvas-blocks-list"
          phx-hook="Sortable"
          data-event-name="reorder_block"
          class="flex-1 space-y-4"
        >
          <div
            :for={block <- @blocks}
            id={"block-#{block.id}"}
            data-id={block.id}
            class="relative group"
          >
            <div class="absolute -left-10 top-1/2 -translate-y-1/2 p-2 opacity-0 group-hover:opacity-50 hover:opacity-100 cursor-grab drag-handle transition-opacity hidden sm:block">
              <.icon name="hero-bars-3" class="size-5" />
            </div>

            <div phx-click="select_block" phx-value-id={block.id}>
              <.content_block block={block} mode={:edit} active={@active_block_id == block.id} />
            </div>

            <%= if @active_block_id == block.id do %>
              <%= if block.type == :quiz_question do %>
                <div class="mt-2 p-6 bg-base-100 ring-1 ring-base-300 rounded-xl shadow-lg border-t-4 border-t-primary animate-in slide-in-from-top-2 duration-200">
                  <div class="text-xs font-bold uppercase tracking-widest text-primary mb-4 border-b border-base-200 pb-2">
                    {gettext("Answer Editor")}
                  </div>
                  <form
                    phx-change="update_quiz_content"
                    phx-submit="ignore"
                    id={"quiz-form-#{block.id}"}
                  >
                    <input type="hidden" name="block_id" value={block.id} />
                    <%= case block.content["question_type"] do %>
                      <% "exact_match" -> %>
                        <div class="form-control">
                          <label class="label">
                            <span class="label-text font-bold text-xs uppercase tracking-wider text-base-content/70">
                              {gettext("Correct Answer (Flag)")}
                            </span>
                          </label>
                          <div class="flex items-center gap-3">
                            <.icon name="hero-flag" class="size-5 text-primary" />
                            <input
                              type="text"
                              name="correct_answer"
                              value={block.content["correct_answer"]}
                              class="input input-bordered flex-1 font-mono"
                              placeholder="flag{...}"
                              phx-debounce="500"
                            />
                          </div>
                        </div>
                      <% type when type in ["single", "multiple"] -> %>
                        <div class="space-y-3" id={"quiz-options-#{block.id}"}>
                          <%= for {opt, index} <- Enum.with_index(block.content["options"] || []) do %>
                            <div class="flex items-start gap-3 group relative">
                              <div class="pt-3 cursor-pointer">
                                <%= if type == "single" do %>
                                  <input
                                    type="radio"
                                    name="correct_option_id"
                                    value={opt["id"]}
                                    checked={opt["is_correct"] in [true, "true"]}
                                    class="radio radio-primary radio-sm"
                                  />
                                  <input
                                    type="hidden"
                                    name={"options[#{index}][is_correct]"}
                                    value="false"
                                  />
                                <% else %>
                                  <input
                                    type="hidden"
                                    name={"options[#{index}][is_correct]"}
                                    value="false"
                                  />
                                  <input
                                    type="checkbox"
                                    name={"options[#{index}][is_correct]"}
                                    value="true"
                                    checked={opt["is_correct"] in [true, "true"]}
                                    class="checkbox checkbox-primary checkbox-sm"
                                  />
                                <% end %>
                              </div>
                              <div class="flex-1 bg-base-100/50 p-2 rounded-lg border border-base-200/50 hover:border-base-300 transition-colors focus-within:border-primary focus-within:ring-1 focus-within:ring-primary space-y-2">
                                <input type="hidden" name={"options[#{index}][id]"} value={opt["id"]} />
                                <input
                                  type="text"
                                  name={"options[#{index}][text]"}
                                  value={opt["text"]}
                                  class="w-full bg-transparent border-none outline-none focus:ring-0 font-medium text-base-content placeholder:text-base-content/30"
                                  placeholder={gettext("Option text")}
                                  phx-debounce="500"
                                />
                                <input
                                  type="text"
                                  name={"options[#{index}][explanation]"}
                                  value={opt["explanation"]}
                                  class="w-full bg-transparent border-none outline-none focus:ring-0 text-sm text-base-content/60 placeholder:text-base-content/30"
                                  placeholder={gettext("Explanation (optional)")}
                                  phx-debounce="500"
                                />
                              </div>
                              <div class="pt-2 opacity-0 group-hover:opacity-100 transition-opacity">
                                <button
                                  type="button"
                                  phx-click="remove_quiz_option"
                                  phx-value-id={block.id}
                                  phx-value-option_id={opt["id"]}
                                  class="btn btn-ghost btn-sm btn-square text-error hover:bg-error/20"
                                >
                                  <.icon name="hero-x-mark" class="size-5" />
                                </button>
                              </div>
                            </div>
                          <% end %>
                        </div>
                        <button
                          type="button"
                          phx-click="add_quiz_option"
                          phx-value-id={block.id}
                          class="btn btn-ghost btn-sm mt-4 text-primary font-bold"
                        >
                          <.icon name="hero-plus" class="size-4 mr-1" /> {gettext("Add Option")}
                        </button>
                      <% "open" -> %>
                        <div class="text-sm text-base-content/50 italic bg-base-200/50 p-4 rounded-lg border border-dashed border-base-300">
                          {gettext("Student will see a text area to write their open answer.")}
                        </div>
                      <% _ -> %>
                    <% end %>
                  </form>
                </div>
              <% end %>

              <%= if block.type == :attachment do %>
                <div class="mt-2 p-4 bg-base-100 ring-1 ring-base-300 rounded-xl shadow-lg animate-in slide-in-from-top-2 duration-200">
                  <div class="text-xs font-bold uppercase tracking-widest text-primary mb-3">
                    {gettext("Manage Files")}
                  </div>
                  <div class="space-y-2">
                    <div
                      :for={file <- block.content["files"] || []}
                      class="flex items-center justify-between p-2 bg-base-200/50 border border-base-300 rounded-lg"
                    >
                      <div class="flex items-center gap-2 min-w-0">
                        <.icon name="hero-document" class="size-4 text-base-content/50 shrink-0" />
                        <span class="text-sm truncate flex-1 font-medium">{file["name"]}</span>
                      </div>
                      <button
                        phx-click="delete_attachment"
                        phx-value-block_id={block.id}
                        phx-value-url={file["url"]}
                        class="btn btn-ghost btn-xs btn-square text-error shrink-0"
                      >
                        <.icon name="hero-trash" class="size-4" />
                      </button>
                    </div>
                  </div>
                  <button
                    phx-click="request_media_upload"
                    phx-value-block_id={block.id}
                    phx-value-media_type="attachment"
                    class="btn btn-primary btn-sm mt-3 w-full shadow-sm"
                  >
                    <.icon name="hero-cloud-arrow-up" class="size-4 mr-1" /> {gettext("Upload File")}
                  </button>
                </div>
              <% end %>

              <%= if block.type in [:image, :video] do %>
                <div class="mt-2 flex justify-end animate-in fade-in duration-200">
                  <button
                    phx-click="request_media_upload"
                    phx-value-block_id={block.id}
                    phx-value-media_type={block.type}
                    class="btn btn-primary btn-sm shadow-sm"
                  >
                    <.icon name="hero-cloud-arrow-up" class="size-4 mr-1" />
                    {if block.content["url"],
                      do: gettext("Replace Media"),
                      else: gettext("Upload Media")}
                  </button>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <div class="sticky bottom-8 mt-auto flex justify-center z-30 pointer-events-none">
          <div class="dropdown dropdown-top dropdown-center pointer-events-auto">
            <div
              tabindex="0"
              role="button"
              class="btn btn-primary btn-circle shadow-2xl size-14 group"
            >
              <.icon name="hero-plus" class="size-8" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-1 menu p-2 shadow-2xl bg-base-100 border border-base-200 rounded-2xl w-100 mb-4 animate-in slide-in-from-bottom-2 duration-200"
            >
              <li class="menu-title text-xs uppercase tracking-widest opacity-50 px-4 py-2">
                {gettext("Add Content")}
              </li>
              <li>
                <.button
                  phx-click="add_text_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-document-text" class="size-5 opacity-50" /> {gettext("Text Block")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_code_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-code-bracket" class="size-5 opacity-50" /> {gettext(
                    "Code Sandbox"
                  )}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_quiz_question_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-question-mark-circle" class="size-5 opacity-50" /> {gettext(
                    "Quiz Question"
                  )}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_quiz_exam_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-academic-cap" class="size-5 opacity-50" /> {gettext("Quiz Exam")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_image_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-photo" class="size-5 opacity-50" /> {gettext("Image")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_video_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-video-camera" class="size-5 opacity-50" /> {gettext("Video")}
                </.button>
              </li>
              <li>
                <.button
                  phx-click="add_attachment_block"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-medium gap-3 h-12"
                >
                  <.icon name="hero-paper-clip" class="size-5 opacity-50" /> {gettext(
                    "Files & Materials"
                  )}
                </.button>
              </li>
              <div class="divider my-1"></div>
              <li>
                <.button
                  phx-click="open_library_picker"
                  onclick="document.activeElement.blur()"
                  class="btn btn-ghost justify-start font-bold text-primary gap-3 h-12"
                >
                  <.icon name="hero-bookmark-square" class="size-5" /> {gettext("Add from Library")}
                </.button>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
