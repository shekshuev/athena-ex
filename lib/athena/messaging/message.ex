defmodule Athena.Messaging.Message do
  @moduledoc """
  A single text message in a conversation.

  `kind` is a discriminator reserved for future non-text message types
  (attachments, shared LMS objects); only `:text` is supported for now.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Messaging.{Conversation, MessageMention}

  @type t :: %__MODULE__{}

  @max_length 4000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    belongs_to :conversation, Conversation
    field :account_id, :binary_id
    field :kind, Ecto.Enum, values: [:text], default: :text
    field :body, :string
    field :edited_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    has_many :mentions, MessageMention

    field :account, :any, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The maximum allowed message length, in characters (matches Mattermost's default)."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Builds a changeset for a new message.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :account_id, :body])
    |> validate_required([:conversation_id, :account_id, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, min: 1, max: @max_length)
  end

  @doc """
  Builds a changeset for editing an existing message's body.
  """
  @spec edit_changeset(t(), map()) :: Ecto.Changeset.t()
  def edit_changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> validate_required([:body])
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, min: 1, max: @max_length)
    |> put_change(:edited_at, DateTime.utc_now())
  end
end
