defmodule Athena.Identity.ApiTokens do
  @moduledoc """
  Personal access tokens for authenticating MCP requests as an existing `Account`.

  A token grants exactly the permissions of the `Account` it is generated
  for (impersonation) — there is no separate service-account concept, since
  `Athena.Identity.Acl` and every `Athena.Content.*` guard already accept any
  `%Account{}` with a preloaded `role`.

  Authorization mirrors every other resource in this app: `mcp.tokens.create`,
  `mcp.tokens.read`, and `mcp.tokens.delete` are checked via `Athena.Identity.Acl`,
  and a role can additionally be scoped with the `"own_only"` policy so it only
  ever sees/manages its own tokens (checked against `ApiToken.owner_id`).
  """

  import Ecto.Query
  alias Athena.Identity.{Account, Acl, ApiToken}
  alias Athena.Repo

  @token_prefix "athn_"

  @doc """
  Generates a new token owned by `account` itself. Requires `"mcp.tokens.create"`.

  Returns the raw token exactly once — only `token_hash`/`token_prefix` are
  persisted, so it can never be recovered after this call returns.
  """
  @spec generate_token(Account.t(), map()) ::
          {:ok, String.t(), ApiToken.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def generate_token(%Account{} = account, attrs) do
    if Acl.can?(account, "mcp.tokens.create") do
      secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      raw_token = @token_prefix <> secret

      changeset_attrs =
        attrs
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("owner_id", account.id)

      %ApiToken{}
      |> ApiToken.changeset(changeset_attrs)
      |> Ecto.Changeset.put_change(:token_hash, hash_secret(secret))
      |> Ecto.Changeset.put_change(:token_prefix, String.slice(secret, 0, 8))
      |> Repo.insert()
      |> case do
        {:ok, token} -> {:ok, raw_token, token}
        error -> error
      end
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Resolves a raw token (as presented in an `Authorization: Bearer` header) to
  the `Account` it was generated for, with `role` preloaded.

  Fails for a missing prefix, unknown token, revoked token, or expired token.
  """
  @spec authenticate_token(String.t()) :: {:ok, Account.t()} | :error
  def authenticate_token(@token_prefix <> secret) do
    token_hash = hash_secret(secret)

    ApiToken
    |> where([t], t.token_hash == ^token_hash)
    |> Repo.one()
    |> case do
      nil -> :error
      token -> validate_token(token)
    end
  end

  def authenticate_token(_invalid), do: :error

  defp validate_token(%ApiToken{revoked_at: revoked_at}) when not is_nil(revoked_at), do: :error

  defp validate_token(%ApiToken{expires_at: expires_at} = token)
       when not is_nil(expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      :error
    else
      touch_and_return(token)
    end
  end

  defp validate_token(token), do: touch_and_return(token)

  defp touch_and_return(%ApiToken{} = token) do
    Repo.update_all(
      from(t in ApiToken, where: t.id == ^token.id),
      set: [last_used_at: DateTime.utc_now(:second)]
    )

    case Repo.get(Account, token.owner_id) do
      nil -> :error
      account -> {:ok, Repo.preload(account, :role)}
    end
  end

  @doc """
  Lists tokens visible to `user` per `"mcp.tokens.read"` (scoped to the
  user's own tokens under the `"own_only"` policy, or every token otherwise),
  excluding revoked ones. Paginated via Flop.
  """
  @spec list_tokens(Account.t(), map()) ::
          {:ok, {[ApiToken.t()], Flop.Meta.t()}} | {:error, Flop.Meta.t()}
  def list_tokens(%Account{} = user, params \\ %{}) do
    ApiToken
    |> where([t], is_nil(t.revoked_at))
    |> Acl.scope_query(user, "mcp.tokens.read")
    |> Flop.validate_and_run(params, for: ApiToken)
  end

  @doc "Revokes a token so it can no longer authenticate requests. Requires `\"mcp.tokens.delete\"`."
  @spec revoke_token(Account.t(), ApiToken.t()) ::
          {:ok, ApiToken.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def revoke_token(%Account{} = user, %ApiToken{} = token) do
    if Acl.can?(user, "mcp.tokens.delete", token) do
      token
      |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now(:second)})
      |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  @doc "Fetches a single token by id, or `{:error, :not_found}`."
  @spec get_token(String.t()) :: {:ok, ApiToken.t()} | {:error, :not_found}
  def get_token(id) do
    case Repo.get(ApiToken, id) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  defp hash_secret(secret), do: :crypto.hash(:sha256, secret)
end
