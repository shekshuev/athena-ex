defmodule Athena.Content.BlockTypes do
  @moduledoc """
  The single source of truth for `Athena.Content.Block` type atoms.

  The type list used to be hand-copied into four schemas, and
  `AthenaWeb.BlockComponents.content_block/1` renders an unknown type as a
  *silent* warning box - so a type added to one copy and forgotten in another
  produced a half-wired block type with no compile error and no crash. Every
  schema now derives its `Ecto.Enum` values from here.

  The subsets are expressed as exclusions from `all/0` rather than as separate
  literal lists, so adding a type is one edit and the reason a type is *not*
  in a subset is written down next to it.
  """

  @all ~w(text code quiz_question quiz_exam ticket_exam video image attachment file_assignment)a

  # Types that cannot be stored as a reusable `Athena.Content.LibraryBlock`.
  @non_library ~w()a

  # Types `Athena.Gamification.XpRule` must not award XP for.
  @non_xp_awardable ~w()a

  # Pure content (text/image/video/attachment) never has a `Submission`, so a
  # "View Submissions" link to the grading screen makes no sense for it.
  @gradable ~w(code quiz_question quiz_exam ticket_exam file_assignment)a

  @library @all -- @non_library
  @xp_awardable @all -- @non_xp_awardable

  @type t :: atom()

  @doc "Every block type."
  @spec all() :: [t()]
  def all, do: @all

  @doc "Types that can be saved to, and inserted from, the content library."
  @spec library() :: [t()]
  def library, do: @library

  @doc "Types an admin can configure a base XP award for."
  @spec xp_awardable() :: [t()]
  def xp_awardable, do: @xp_awardable

  @doc "Types that can carry student submissions, and so can be graded."
  @spec gradable() :: [t()]
  def gradable, do: @gradable

  @doc "Whether a block of this type can have student submissions at all."
  @spec gradable?(t()) :: boolean()
  def gradable?(type), do: type in @gradable
end
