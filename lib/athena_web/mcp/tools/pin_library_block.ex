defmodule AthenaWeb.MCP.Tools.PinLibraryBlock do
  @moduledoc "MCP tool: pin_library_block."
  @behaviour EMCP.Tool

  alias Athena.Content
  alias AthenaWeb.MCP.Tools.Errors

  @impl EMCP.Tool
  def name, do: "pin_library_block"

  @impl EMCP.Tool
  def description,
    do:
      "Pins a library block into a course's workspace. This is what makes it eligible for " <>
        "THAT COURSE's quiz_exam/ticket_exam question pools - owning/editing a library block " <>
        "is not enough on its own, and pinning it to one course has no effect on any other " <>
        "course. See athena://docs/library-and-exams."

  @impl EMCP.Tool
  def input_schema do
    %{
      type: :object,
      properties: %{
        course_id: %{type: :string},
        library_block_id: %{type: :string}
      },
      required: [:course_id, :library_block_id]
    }
  end

  @impl EMCP.Tool
  def call(conn, %{"course_id" => course_id, "library_block_id" => library_block_id}) do
    user = conn.assigns.current_user

    case Content.pin_library_block(user, course_id, library_block_id) do
      {:ok, _pin} -> Errors.ok(%{course_id: course_id, library_block_id: library_block_id})
      error -> Errors.error(error)
    end
  end
end
