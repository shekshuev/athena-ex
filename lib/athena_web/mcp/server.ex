defmodule AthenaWeb.MCP.Server do
  @moduledoc """
  MCP server exposing course/content management tools over the `/mcp`
  StreamableHTTP endpoint. Every tool call runs as the `%Account{}` resolved
  by `AthenaWeb.Plugs.FetchCurrentUserFromToken` from the request's Bearer
  token — see that plug and `AthenaWeb.MCP.Tools.Errors` for the auth/error
  contract every tool module follows.
  """

  use EMCP.Server,
    name: "athena",
    version: "1.0.0",
    title: "Athena LMS",
    description: "Create and manage Athena courses, sections, blocks, and library content.",
    tools: [
      AthenaWeb.MCP.Tools.ListCourses,
      AthenaWeb.MCP.Tools.SearchCourses,
      AthenaWeb.MCP.Tools.GetCourseTree,
      AthenaWeb.MCP.Tools.CreateCourse,
      AthenaWeb.MCP.Tools.UpdateCourse,
      AthenaWeb.MCP.Tools.SoftDeleteCourse,
      AthenaWeb.MCP.Tools.DuplicateCourse,
      AthenaWeb.MCP.Tools.CreateSection,
      AthenaWeb.MCP.Tools.UpdateSection,
      AthenaWeb.MCP.Tools.DeleteSection,
      AthenaWeb.MCP.Tools.CreateBlock,
      AthenaWeb.MCP.Tools.UpdateBlock,
      AthenaWeb.MCP.Tools.DeleteBlock,
      AthenaWeb.MCP.Tools.CreateLibraryBlock,
      AthenaWeb.MCP.Tools.PinLibraryBlock,
      AthenaWeb.MCP.Tools.ListLibraryBlocks,
      AthenaWeb.MCP.Tools.PrepareMediaUpload,
      AthenaWeb.MCP.Tools.AttachMediaToBlock
    ],
    resources: [
      AthenaWeb.MCP.Resources.BlockContentSchemas,
      AthenaWeb.MCP.Resources.ProgressionRules,
      AthenaWeb.MCP.Resources.MediaUploads,
      AthenaWeb.MCP.Resources.LibraryAndExams
    ]
end
