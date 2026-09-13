defmodule Athena.Messaging.ConversationParticipant do
  @moduledoc """
  Membership of an account within a conversation, and the read-cursor
  (`last_read_at`) used to compute unread counts for that account.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Messaging.Conversation

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_participants" do
    belongs_to :conversation, Conversation
    field :account_id, :binary_id
    field :last_read_at, :utc_datetime_usec

    field :account, :any, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:conversation_id, :account_id, :last_read_at])
    |> validate_required([:conversation_id, :account_id])
    |> unique_constraint([:conversation_id, :account_id],
      name: :conversation_participants__conversation_id_account_id__uk
    )
  end
end
