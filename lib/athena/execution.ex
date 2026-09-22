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
  defdelegate cm_languages, to: LanguageConfig

  @doc """
  Returns whether a runner node able to execute the given language is
  currently connected to the cluster.
  """
  @spec runner_available?(String.t()) :: boolean()
  def runner_available?(language), do: match?({:ok, _pid}, pick_runner(language))

  @doc """
  Picks a random connected runner node able to execute the given language.
  """
  @spec pick_runner(String.t()) :: {:ok, pid()} | :error
  def pick_runner(language) do
    with %LanguageConfig{family: family} <- LanguageConfig.get(language),
         runners when runners != [] <- :pg.get_members(Athena.PG, {:code_runners, family}) do
      {:ok, Enum.random(runners)}
    else
      _ -> :error
    end
  end
end
