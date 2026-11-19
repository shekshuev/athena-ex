defmodule Athena.Content.LibraryAccessTest do
  use Athena.DataCase, async: true
  import Athena.Factory
  alias Athena.{Content, Repo}
  alias Athena.Content.{CourseLibraryBlock, Library, LibraryAccess, LibraryBlock}

  setup do
    permissions =
      ~w(library.read library.update library.delete library.create courses.read courses.update courses.delete competitions.read competitions.update)

    role =
      insert(:role, permissions: permissions, policies: Map.new(permissions, &{&1, ["own_only"]}))

    owner = insert(:account, role: role)
    writer = insert(:account, role: role)
    reader = insert(:account, role: role)
    stranger = insert(:account, role: role)
    course = insert(:course, owner_id: owner.id)
    block = insert(:library_block, owner_id: owner.id)
    foreign = insert(:library_block, owner_id: stranger.id)
    insert(:course_library_block, course: course, library_block: block)
    insert(:course_library_block, course: course, library_block: foreign)
    writer_share = insert(:course_share, course: course, account_id: writer.id, role: :writer)
    insert(:course_share, course: course, account_id: reader.id, role: :reader)

    %{
      owner: owner,
      writer: writer,
      reader: reader,
      stranger: stranger,
      course: course,
      block: block,
      foreign: foreign,
      writer_share: writer_share
    }
  end

  test "course readers read pinned templates and writers edit only course-owner templates", ctx do
    for user <- [ctx.writer, ctx.reader] do
      assert {:ok, _} = Content.get_library_block(user, ctx.block.id)
      assert {:ok, _} = Content.get_library_block(user, ctx.foreign.id)
    end

    assert %{role: :writer, can_edit: true, can_manage: false, can_delete: false} =
             Content.library_block_access(ctx.writer, ctx.block)

    assert Content.library_block_access(ctx.reader, ctx.block).role == :reader
    refute LibraryAccess.editable?(ctx.reader, ctx.block)
    refute LibraryAccess.editable?(ctx.writer, ctx.foreign)

    assert {:ok, _} =
             Content.update_library_block(ctx.writer, ctx.block, %{"title" => "Shared edit"})

    assert {:error, :forbidden} =
             Content.update_library_block(ctx.reader, ctx.block, %{"title" => "Forbidden"})

    assert {:error, :forbidden} =
             Content.update_library_block(ctx.writer, ctx.foreign, %{"title" => "Forbidden"})
  end

  test "foreign templates require their own writer grant", ctx do
    insert(:library_block_share,
      library_block: ctx.foreign,
      account_id: ctx.writer.id,
      role: :reader
    )

    refute LibraryAccess.editable?(ctx.writer, ctx.foreign)
    assert {:ok, _} = Library.share_block(ctx.stranger, ctx.foreign, ctx.writer.id, :writer)
    assert LibraryAccess.editable?(ctx.writer, ctx.foreign)

    assert {:ok, _} =
             Content.update_library_block(ctx.writer, ctx.foreign, %{"title" => "Explicit writer"})
  end

  test "course inheritance grants no management or protected metadata writes", ctx do
    assert {:error, :forbidden} =
             Library.share_block(ctx.writer, ctx.block, ctx.stranger.id, :writer)

    assert {:error, :forbidden} = Library.revoke_block_share(ctx.writer, ctx.block, ctx.reader.id)
    assert {:error, :forbidden} = Library.toggle_block_public(ctx.writer, ctx.block, true)
    assert {:error, :forbidden} = Library.delete_library_block(ctx.writer, ctx.block)

    for attrs <- [
          %{"owner_id" => ctx.writer.id},
          %{"is_public" => true},
          %{owner_id: ctx.writer.id},
          %{is_public: true}
        ] do
      assert {:error, :forbidden} = Library.update_library_block(ctx.writer, ctx.block, attrs)
    end

    assert Repo.get!(LibraryBlock, ctx.block.id).owner_id == ctx.owner.id
    refute Repo.get!(LibraryBlock, ctx.block.id).is_public
  end

  test "an unrelated reader cannot access a private template pinned to someone else's course",
       ctx do
    assert {:error, :not_found} = Content.get_library_block(ctx.stranger, ctx.block.id)
    assert Content.library_block_access(ctx.stranger, ctx.block).role == :none

    assert {:ok, {blocks, _}} =
             Content.list_library_blocks(ctx.stranger, %{"course_id" => ctx.course.id})

    refute Enum.any?(blocks, &(&1.id == ctx.block.id))
  end

  test "pinning an unreadable block by ID cannot bootstrap read or write access", ctx do
    own_course = insert(:course, owner_id: ctx.stranger.id)

    assert {:error, :forbidden} =
             Content.pin_library_block(ctx.stranger, own_course.id, ctx.block.id)

    refute Repo.get_by(CourseLibraryBlock,
             course_id: own_course.id,
             library_block_id: ctx.block.id
           )

    refute LibraryAccess.readable?(ctx.stranger, ctx.block.id)
    refute LibraryAccess.editable?(ctx.stranger, ctx.block)
  end

  test "downgrading or revoking the course grant immediately changes access", ctx do
    assert {:ok, _} = Content.share_course(ctx.owner, ctx.course, ctx.writer.id, :reader)
    assert LibraryAccess.readable?(ctx.writer, ctx.block.id)
    refute LibraryAccess.editable?(ctx.writer, ctx.block)
    assert {:ok, :revoked} = Content.revoke_course_share(ctx.owner, ctx.course, ctx.writer.id)
    refute LibraryAccess.readable?(ctx.writer, ctx.block.id)

    assert {:error, :forbidden} =
             Content.update_library_block(ctx.writer, ctx.block, %{"title" => "Stale write"})
  end

  test "unpinning revokes inheritance but independent direct grants survive", ctx do
    assert {:ok, _} = Content.unpin_library_block(ctx.owner, ctx.course.id, ctx.block.id)
    refute LibraryAccess.readable?(ctx.writer, ctx.block.id)
    refute LibraryAccess.editable?(ctx.writer, ctx.block)
    Library.share_block(ctx.owner, ctx.block, ctx.writer.id, :writer)
    assert LibraryAccess.readable?(ctx.writer, ctx.block.id)
    assert LibraryAccess.editable?(ctx.writer, ctx.block)
  end

  test "deleted courses and reassigned block ownership do not leave inherited grants", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.block, owner_id: ctx.stranger.id))
    refute LibraryAccess.editable?(ctx.writer, ctx.block)
    assert {:ok, _} = Content.soft_delete_course(ctx.owner, ctx.course)
    refute LibraryAccess.readable?(ctx.writer, ctx.foreign.id)
  end

  test "both library and course base permissions are required", ctx do
    for missing <- ["library.read", "library.update", "courses.update", "courses.read"] do
      role =
        insert(:role,
          permissions: ctx.writer.role.permissions -- [missing],
          policies: ctx.writer.role.policies
        )

      user = insert(:account, role: role)
      insert(:course_share, course: ctx.course, account_id: user.id, role: :writer)
      refute LibraryAccess.editable?(user, ctx.block)
    end
  end

  test "a per-template reader grant does not override an independent course writer grant", ctx do
    insert(:library_block_share,
      library_block: ctx.block,
      account_id: ctx.writer.id,
      role: :reader
    )

    assert LibraryAccess.editable?(ctx.writer, ctx.block)
    assert {:ok, _} = Content.share_course(ctx.owner, ctx.course, ctx.writer.id, :reader)
    refute LibraryAccess.editable?(ctx.writer, ctx.block)
    assert LibraryAccess.readable?(ctx.writer, ctx.block.id)
  end

  test "another writable course keeps inheritance after one pin is removed", ctx do
    other_course = insert(:course, owner_id: ctx.owner.id)
    insert(:course_share, course: other_course, account_id: ctx.writer.id, role: :writer)
    insert(:course_library_block, course: other_course, library_block: ctx.block)
    assert {:ok, _} = Content.unpin_library_block(ctx.owner, ctx.course.id, ctx.block.id)
    assert LibraryAccess.editable?(ctx.writer, ctx.block)
    assert {:ok, :revoked} = Content.revoke_course_share(ctx.owner, other_course, ctx.writer.id)
    refute LibraryAccess.editable?(ctx.writer, ctx.block)
  end

  test "competition inheritance uses the competition permission", ctx do
    competition = insert(:course, type: :competition, owner_id: ctx.owner.id)
    question = insert(:library_block, owner_id: ctx.owner.id)
    insert(:course_library_block, course: competition, library_block: question)
    insert(:course_share, course: competition, account_id: ctx.writer.id, role: :writer)
    assert LibraryAccess.editable?(ctx.writer, question)

    role =
      insert(:role,
        permissions: ctx.writer.role.permissions -- ["competitions.update"],
        policies: ctx.writer.role.policies
      )

    user = insert(:account, role: role)
    insert(:course_share, course: competition, account_id: user.id, role: :writer)
    refute LibraryAccess.editable?(user, question)
  end

  test "course copies belong to its owner and can be edited by its collaborators", ctx do
    assert {:ok, copy} =
             Content.duplicate_library_block_for_course(ctx.writer, ctx.course.id, ctx.foreign.id)

    assert copy.owner_id == ctx.owner.id
    refute copy.is_public
    refute copy.id == ctx.foreign.id
    assert Repo.get_by(CourseLibraryBlock, course_id: ctx.course.id, library_block_id: copy.id)
    assert LibraryAccess.editable?(ctx.writer, copy)

    assert {:ok, _} =
             Content.update_library_block(ctx.writer, copy, %{"title" => "Course copy edited"})

    assert Repo.get!(LibraryBlock, ctx.foreign.id).title == ctx.foreign.title

    assert {:error, :forbidden} =
             Content.duplicate_library_block_for_course(ctx.reader, ctx.course.id, ctx.foreign.id)
  end
end
