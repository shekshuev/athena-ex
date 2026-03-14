defmodule Athena.Identity.AclTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  alias Athena.Identity.Acl

  defmodule DummyResource do
    use Ecto.Schema

    schema "dummy_resources" do
      field :owner_id, :binary_id
      field :is_published, :boolean
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

  defp build_resource(owner_id, is_published \\ false) do
    %{
      owner_id: owner_id,
      is_published: is_published
    }
  end

  describe "can?/3" do
    test "returns false if user is nil" do
      assert Acl.can?(nil, "some_permission", %{}) == false
    end

    test "admin bypasses all checks" do
      admin = build_user(1, ["admin"])
      resource = build_resource(2, false)

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

    test "evaluates 'not_published' policy" do
      user = build_user(1, ["courses.read"], %{"courses.read" => ["not_published"]})

      draft_resource = build_resource(2, false)
      published_resource = build_resource(2, true)

      assert Acl.can?(user, "courses.read", draft_resource) == true
      assert Acl.can?(user, "courses.read", published_resource) == false
    end

    test "evaluates 'only_published' policy" do
      user = build_user(1, ["courses.read"], %{"courses.read" => ["only_published"]})

      draft_resource = build_resource(2, false)
      published_resource = build_resource(2, true)

      assert Acl.can?(user, "courses.read", draft_resource) == false
      assert Acl.can?(user, "courses.read", published_resource) == true
    end

    test "evaluates 'published_or_owner' policy" do
      user = build_user(1, ["courses.read"], %{"courses.read" => ["published_or_owner"]})

      own_draft = build_resource(1, false)
      other_published = build_resource(2, true)
      other_draft = build_resource(2, false)

      assert Acl.can?(user, "courses.read", own_draft) == true
      assert Acl.can?(user, "courses.read", other_published) == true
      assert Acl.can?(user, "courses.read", other_draft) == false
    end

    test "evaluates multiple policies combined (AND logic)" do
      user = build_user(1, ["courses.read"], %{"courses.read" => ["own_only", "only_published"]})

      own_published = build_resource(1, true)
      own_draft = build_resource(1, false)
      other_published = build_resource(2, true)

      assert Acl.can?(user, "courses.read", own_published) == true
      assert Acl.can?(user, "courses.read", own_draft) == false
      assert Acl.can?(user, "courses.read", other_published) == false
    end

    test "returns false for unknown policy (fail-safe)" do
      user = build_user(1, ["courses.read"], %{"courses.read" => ["some_bullshit_policy"]})
      resource = build_resource(1, true)

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

    test "applies 'not_published' condition to query", %{base_query: query} do
      user = build_user(1, ["read"], %{"read" => ["not_published"]})
      scoped_query = Acl.scope_query(query, user, "read")

      query_str = inspect(scoped_query)
      assert query_str =~ "d0.is_published == false"
    end

    test "applies 'only_published' condition to query", %{base_query: query} do
      user = build_user(1, ["read"], %{"read" => ["only_published"]})
      scoped_query = Acl.scope_query(query, user, "read")

      query_str = inspect(scoped_query)
      assert query_str =~ "d0.is_published == true"
    end

    test "applies 'published_or_owner' condition to query", %{base_query: query} do
      user = build_user(123, ["read"], %{"read" => ["published_or_owner"]})
      scoped_query = Acl.scope_query(query, user, "read")

      query_str = inspect(scoped_query)
      assert query_str =~ "d0.is_published == true or d0.owner_id == ^"
    end

    test "applies multiple conditions to query (AND logic)", %{base_query: query} do
      user = build_user(123, ["read"], %{"read" => ["own_only", "only_published"]})
      scoped_query = Acl.scope_query(query, user, "read")

      query_str = inspect(scoped_query)
      assert query_str =~ "d0.owner_id == ^"
      assert query_str =~ "d0.is_published == true"
    end
  end
end
