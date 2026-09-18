defmodule Athena.Identity.ApiTokensTest do
  use Athena.DataCase, async: true

  alias Athena.Identity.ApiTokens
  import Athena.Factory

  setup do
    account = insert(:account, role: insert(:role, permissions: ["mcp.tokens.create"]))
    powerless_account = insert(:account, role: insert(:role, permissions: []))

    %{account: account, powerless_account: powerless_account}
  end

  describe "generate_token/2" do
    test "returns a raw token once and persists only its hash, owned by the caller", %{
      account: account
    } do
      {:ok, raw_token, token} = ApiTokens.generate_token(account, %{"label" => "my agent"})

      assert String.starts_with?(raw_token, "athn_")
      assert token.owner_id == account.id
      assert token.label == "my agent"
      assert token.token_hash != raw_token
      assert byte_size(token.token_hash) == 32
    end

    test "requires mcp.tokens.create", %{powerless_account: account} do
      assert {:error, :forbidden} = ApiTokens.generate_token(account, %{"label" => "my agent"})
    end
  end

  describe "authenticate_token/1" do
    test "round-trips a freshly generated token back to its account", %{account: account} do
      {:ok, raw_token, _token} = ApiTokens.generate_token(account, %{"label" => "my agent"})

      assert {:ok, resolved} = ApiTokens.authenticate_token(raw_token)
      assert resolved.id == account.id
      assert resolved.role
    end

    test "bumps last_used_at on success", %{account: account} do
      {:ok, raw_token, token} = ApiTokens.generate_token(account, %{"label" => "my agent"})
      assert is_nil(token.last_used_at)

      {:ok, _} = ApiTokens.authenticate_token(raw_token)

      reloaded = Repo.get!(Athena.Identity.ApiToken, token.id)
      refute is_nil(reloaded.last_used_at)
    end

    test "rejects an unknown token" do
      assert :error = ApiTokens.authenticate_token("athn_does-not-exist")
    end

    test "rejects a malformed token (missing prefix)" do
      assert :error = ApiTokens.authenticate_token("not-a-valid-token")
    end

    test "rejects a revoked token", %{account: account} do
      account = %{
        account
        | role: insert(:role, permissions: ["mcp.tokens.create", "mcp.tokens.delete"])
      }

      {:ok, raw_token, token} = ApiTokens.generate_token(account, %{"label" => "my agent"})
      {:ok, _} = ApiTokens.revoke_token(account, token)

      assert :error = ApiTokens.authenticate_token(raw_token)
    end

    test "rejects an expired token", %{account: account} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, raw_token, token} =
        ApiTokens.generate_token(account, %{"label" => "my agent", "expires_at" => past})

      assert token.expires_at
      assert :error = ApiTokens.authenticate_token(raw_token)
    end
  end

  describe "revoke_token/2" do
    test "owner with mcp.tokens.delete can revoke their own token", %{account: account} do
      role = insert(:role, permissions: ["mcp.tokens.create", "mcp.tokens.delete"])
      account = %{account | role: role}
      {:ok, _raw_token, token} = ApiTokens.generate_token(account, %{"label" => "my agent"})

      assert {:ok, revoked} = ApiTokens.revoke_token(account, token)
      refute is_nil(revoked.revoked_at)
    end

    test "own_only-scoped role cannot revoke someone else's token", %{
      account: owner,
      powerless_account: outsider
    } do
      outsider_role =
        insert(:role,
          permissions: ["mcp.tokens.delete"],
          policies: %{"mcp.tokens.delete" => ["own_only"]}
        )

      outsider = %{outsider | role: outsider_role}
      {:ok, _raw_token, token} = ApiTokens.generate_token(owner, %{"label" => "owner's token"})

      assert {:error, :forbidden} = ApiTokens.revoke_token(outsider, token)
    end

    test "a role with unrestricted mcp.tokens.delete can revoke anyone's token", %{
      account: owner,
      powerless_account: admin_like
    } do
      admin_like_role = insert(:role, permissions: ["mcp.tokens.delete"])
      admin_like = %{admin_like | role: admin_like_role}
      {:ok, _raw_token, token} = ApiTokens.generate_token(owner, %{"label" => "owner's token"})

      assert {:ok, revoked} = ApiTokens.revoke_token(admin_like, token)
      refute is_nil(revoked.revoked_at)
    end
  end

  describe "list_tokens/2" do
    test "own_only-scoped role only sees its own tokens", %{
      account: owner,
      powerless_account: other
    } do
      owner_role = insert(:role, permissions: ["mcp.tokens.create", "mcp.tokens.read"])
      owner = %{owner | role: owner_role}
      {:ok, _, mine} = ApiTokens.generate_token(owner, %{"label" => "mine"})

      other_role = insert(:role, permissions: ["mcp.tokens.create"])
      other = %{other | role: other_role}
      {:ok, _, _theirs} = ApiTokens.generate_token(other, %{"label" => "theirs"})

      reader_role =
        insert(:role,
          permissions: ["mcp.tokens.read"],
          policies: %{"mcp.tokens.read" => ["own_only"]}
        )

      reader = %{owner | role: reader_role}

      {:ok, {tokens, _meta}} = ApiTokens.list_tokens(reader, %{})

      assert Enum.map(tokens, & &1.id) == [mine.id]
    end

    test "unrestricted mcp.tokens.read sees every token", %{
      account: owner,
      powerless_account: other
    } do
      owner_role = insert(:role, permissions: ["mcp.tokens.create"])
      owner = %{owner | role: owner_role}
      {:ok, _, mine} = ApiTokens.generate_token(owner, %{"label" => "mine"})

      other_role = insert(:role, permissions: ["mcp.tokens.create"])
      other = %{other | role: other_role}
      {:ok, _, theirs} = ApiTokens.generate_token(other, %{"label" => "theirs"})

      admin_like_role = insert(:role, permissions: ["mcp.tokens.read"])
      admin_like = %{owner | role: admin_like_role}

      {:ok, {tokens, _meta}} = ApiTokens.list_tokens(admin_like, %{})

      assert MapSet.new(Enum.map(tokens, & &1.id)) == MapSet.new([mine.id, theirs.id])
    end

    test "excludes revoked tokens", %{account: account} do
      role =
        insert(:role, permissions: ["mcp.tokens.create", "mcp.tokens.read", "mcp.tokens.delete"])

      account = %{account | role: role}
      {:ok, _, token} = ApiTokens.generate_token(account, %{"label" => "mine"})
      {:ok, _} = ApiTokens.revoke_token(account, token)

      {:ok, {tokens, _meta}} = ApiTokens.list_tokens(account, %{})

      assert tokens == []
    end
  end
end
