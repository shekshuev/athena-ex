defmodule Athena.Learning.Submissions do
  @moduledoc """
  Internal business logic for Submission management.

  Handles creation, retrieval, and updates of student answers
  (submissions) for specific content blocks.
  """

  import Ecto.Query
  alias Athena.Repo
  alias Athena.Learning.Submission

  @doc """
  Gets a student's latest submission for a specific block.

  Returns `nil` if no submission exists.
  """
  @spec get_submission(String.t(), String.t()) :: Submission.t() | nil
  def get_submission(account_id, block_id) do
    Submission
    |> where([s], s.account_id == ^account_id and s.block_id == ^block_id)
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Creates a new submission.
  """
  @spec create_submission(map()) :: {:ok, Submission.t()} | {:error, Ecto.Changeset.t()}
  def create_submission(attrs) do
    %Submission{}
    |> Submission.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing submission.
  """
  @spec update_submission(Submission.t(), map()) ::
          {:ok, Submission.t()} | {:error, Ecto.Changeset.t()}
  def update_submission(%Submission{} = submission, attrs) do
    submission
    |> Submission.changeset(attrs)
    |> Repo.update()
  end
end
