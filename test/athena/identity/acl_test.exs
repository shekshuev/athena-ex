defmodule Athena.Identity.AclTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  alias Athena.Identity.Acl

  defmodule DummyResource do
    use Ecto.Schema

    schema "dummy_resources" do
      field :owner_id, :binary_id
    end
  end

  defp build_user(id, permissions, policies \\ %{}) do
    %{
      id: id,
      role: %{
        permissions: permissions,
        policies: policies
      }
    }
  end

  defp build_resource(owner_id) do
    %{
      owner_id: owner_id
    }
  end

  describe "can?/3" do
    test "returns false if user is nil" do
      assert Acl.can?(nil, "some_permission", %{}) == false
    end

    test "admin bypasses all checks" do
      admin = build_user(1, ["admin"])
      resource = build_resource(2)

      assert Acl.can?(admin, "courses.read", resource) == true
      assert Acl.can?(admin, "courses.delete", resource) == true
    end

    test "returns false if user lacks permission" do
      user = build_user(1, ["articles.read"])
      assert Acl.can?(user, "courses.read") == false
    end

    test "returns true if user has permission but no policies" do
      user = build_user(1, ["courses.read"])
      assert Acl.can?(user, "courses.read") == true
    end

    test "returns true if user has policies but resource is nil (e.g., rendering menu)" do
      user = build_user(1, ["courses.read"], %{"courses.read" => ["own_only"]})
      assert Acl.can?(user, "courses.read", nil) == true
    end

    test "evaluates 'own_only' policy" do
      user = build_user(1, ["courses.read"], %{"courses.read" => ["own_only"]})

      own_resource = build_resource(1)
      other_resource = build_resource(2)

      assert Acl.can?(user, "courses.read", own_resource) == true
      assert Acl.can?(user, "courses.read", other_resource) == false
    end

    test "returns false for unknown policy (fail-safe)" do
      user = build_user(1, ["courses.read"], %{"courses.read" => ["some_bullshit_policy"]})
      resource = build_resource(1)

      assert Acl.can?(user, "courses.read", resource) == false
    end
  end

  describe "scope_query/3" do
    setup do
      %{base_query: from(d in DummyResource)}
    end

    test "returns query with 'where: false' if user is nil", %{base_query: query} do
      scoped_query = Acl.scope_query(query, nil, "read")
      assert inspect(scoped_query) =~ "where: false"
    end

    test "returns unmodified query for admin", %{base_query: query} do
      admin = build_user(1, ["admin"])
      scoped_query = Acl.scope_query(query, admin, "some_permission")

      assert inspect(scoped_query) == inspect(query)
    end

    test "returns query with 'where: false' if user lacks permission", %{base_query: query} do
      user = build_user(1, ["other_permission"])
      scoped_query = Acl.scope_query(query, user, "target_permission")

      assert inspect(scoped_query) =~ "where: false"
    end

    test "returns unmodified query if user has permission but no policies", %{base_query: query} do
      user = build_user(1, ["read"])
      scoped_query = Acl.scope_query(query, user, "read")

      assert inspect(scoped_query) == inspect(query)
    end

    test "applies 'own_only' condition to query", %{base_query: query} do
      user = build_user(123, ["read"], %{"read" => ["own_only"]})
      scoped_query = Acl.scope_query(query, user, "read")

      query_str = inspect(scoped_query)
      assert query_str =~ "d0.owner_id == ^"
    end
  end
end
