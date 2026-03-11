defmodule Athena.Identity.ACLTest do
  use Athena.DataCase, async: true

  alias Athena.Identity.ACL
  import Ecto.Query

  describe "check/3" do
    test "should check own_only policy" do
      assert ACL.check("own_only", "user-123", %{owner_id: "user-123"})
      refute ACL.check("own_only", "user-123", %{owner_id: "hacker-999"})
    end

    test "should check not_published policy" do
      assert ACL.check("not_published", "any-user", %{is_published: false})
      refute ACL.check("not_published", "any-user", %{is_published: true})
    end

    test "should check only_published policy" do
      assert ACL.check("only_published", "any-user", %{is_published: true})
      refute ACL.check("only_published", "any-user", %{is_published: false})
    end

    test "should check published_or_owner policy" do
      assert ACL.check("published_or_owner", "user-1", %{owner_id: "user-2", is_published: true})
      assert ACL.check("published_or_owner", "user-1", %{owner_id: "user-1", is_published: false})
      refute ACL.check("published_or_owner", "user-1", %{owner_id: "user-2", is_published: false})
    end

    test "should refute on unknown policy" do
      refute ACL.check("some_bullshit_policy", "user-1", %{owner_id: "user-1"})
    end
  end

  describe "apply_policies/3" do
    setup do
      {:ok, base_query: from(c in "courses", select: [:id, :owner_id, :is_published])}
    end

    test "should return initial query when no policies provided", %{base_query: query} do
      result_query = ACL.apply_policies(query, "user-1", [])
      assert result_query == query
    end

    test "should add owner_id filter", %{base_query: query} do
      result_query = ACL.apply_policies(query, "user-1", ["own_only"])

      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Athena.Repo, result_query)

      assert sql =~ "owner_id\" = $1"
      assert params == ["user-1"]
    end

    test "should add is_published filter", %{base_query: query} do
      result_query = ACL.apply_policies(query, "user-1", ["only_published"])

      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Athena.Repo, result_query)

      assert sql =~ "is_published\" ="
    end

    test "should add owner_id or is_published filter", %{base_query: query} do
      result_query = ACL.apply_policies(query, "user-1", ["published_or_owner"])

      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Athena.Repo, result_query)

      assert sql =~ "is_published\" ="
      assert sql =~ "OR"
      assert sql =~ "owner_id\" = $1"
      assert params == ["user-1"]
    end

    test "should merge several policies via AND", %{base_query: query} do
      result_query = ACL.apply_policies(query, "user-1", ["own_only", "only_published"])

      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Athena.Repo, result_query)

      assert sql =~ "owner_id\" = $1"
      assert sql =~ "AND"
      assert sql =~ "is_published\" ="
      assert params == ["user-1"]
    end
  end
end
