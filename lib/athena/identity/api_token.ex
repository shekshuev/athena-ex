defmodule Athena.Identity.ApiToken do
  @moduledoc """
  A personal access token used to authenticate MCP requests as an `Account`.

  Only `token_hash` (a SHA-256 digest of the token secret) is ever persisted;
  the raw token is generated and returned once by `Athena.Identity.ApiTokens.generate_token/2`
  and never stored anywhere.

  `owner_id` is a plain scalar field (not a `belongs_to`), same convention as
  `Course.owner_id`/`LibraryBlock.owner_id` - it's what `Athena.Identity.Acl`'s
  `"own_only"` policy checks against for the `mcp.tokens.*` permissions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:label, :owner_id],
    sortable: [:label, :last_used_at, :expires_at, :inserted_at],
    default_limit: 10,
    default_order: %{
      order_by: [:inserted_at],
      order_directions: [:desc]
    }
  }

  schema "api_tokens" do
    field :label, :string
    field :token_hash, :binary
    field :token_prefix, :string
    field :owner_id, :binary_id
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for token creation. `token_hash`/`token_prefix` are set
  separately by the context after generating the raw secret.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:label, :owner_id, :expires_at])
    |> validate_required([:label, :owner_id])
    |> validate_length(:label, min: 1, max: 100)
    |> foreign_key_constraint(:owner_id)
  end
end
