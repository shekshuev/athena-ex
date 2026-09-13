defmodule Athena.Messaging.MessageMention do
  @moduledoc """
  Records that an account was `@mentioned` in a message, along with the
  exact matched text (e.g. `"@Jane Doe"`) so it can be highlighted at
  render time without re-deriving it from the current profile name.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Messaging.Message

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_mentions" do
    belongs_to :message, Message
    field :account_id, :binary_id
    field :matched_text, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(mention, attrs) do
    mention
    |> cast(attrs, [:message_id, :account_id, :matched_text])
    |> validate_required([:message_id, :account_id, :matched_text])
    |> unique_constraint([:message_id, :account_id],
      name: :message_mentions__message_id_account_id__uk
    )
  end
end
