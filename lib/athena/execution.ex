defmodule Athena.Execution do
  @moduledoc """
  Public API for the Execution context.

  Delegates read operations to specialized internal modules.
  """

  alias Athena.Execution.Verifier
  alias Athena.Execution.LanguageConfig

  defdelegate verify(code, challenge, box_id), to: Verifier

  defdelegate options, to: LanguageConfig
  defdelegate default_language, to: LanguageConfig
  defdelegate cm_lang(lang), to: LanguageConfig
end
