defmodule Athena.Messaging.Conversation do
  @moduledoc """
  A conversation is either a direct (1:1) chat between two accounts, or the
  single group chat automatically provisioned for a cohort.

  Cross-context references (`cohort_id`) are bare `:binary_id` fields with no
  `belongs_to`/FK, matching the rest of the app's convention for referencing
  another context's data (see `Athena.Learning.CohortMembership.account_id`).
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Messaging.ConversationParticipant

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :kind, Ecto.Enum, values: [:direct, :cohort]
    field :cohort_id, :binary_id
    field :direct_key, :string
    field :last_message_at, :utc_datetime_usec

    has_many :participants, ConversationParticipant

    # Enrichment (populated by Athena.Messaging.Conversations, not by Ecto associations)
    field :cohort, :any, virtual: true
    field :other_participant, :any, virtual: true
    field :unread_count, :integer, virtual: true, default: 0
    field :has_unread_mention, :boolean, virtual: true, default: false
    field :last_message, :any, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:kind, :cohort_id, :direct_key, :last_message_at])
    |> validate_required([:kind])
    |> validate_cohort_id()
    |> unique_constraint(:direct_key, name: :conversations__direct_key__uk)
    |> unique_constraint(:cohort_id, name: :conversations__cohort_id__uk)
  end

  defp validate_cohort_id(changeset) do
    if get_field(changeset, :kind) == :cohort do
      validate_required(changeset, [:cohort_id])
    else
      changeset
    end
  end
end
