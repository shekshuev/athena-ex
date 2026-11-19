defmodule AthenaWeb.StudioLive.LibraryCourseAccessTest do
  use AthenaWeb.ConnCase, async: true
  import Athena.Factory
  import Phoenix.LiveViewTest
  alias Athena.{Content, Repo}
  alias Athena.Content.{CourseLibraryBlock, LibraryBlock}

  setup %{conn: conn} do
    permissions =
      ~w(library.read library.update library.delete library.create courses.read courses.update)

    role =
      insert(:role, permissions: permissions, policies: Map.new(permissions, &{&1, ["own_only"]}))

    owner = insert(:account, role: role)
    writer = insert(:account, role: role)
    reader = insert(:account, role: role)
    course = insert(:course, owner_id: owner.id)
    block = insert(:library_block, owner_id: owner.id)
    foreign = insert(:library_block)
    insert(:course_library_block, course: course, library_block: block)
    insert(:course_library_block, course: course, library_block: foreign)
    share = insert(:course_share, course: course, account_id: writer.id, role: :writer)
    insert(:course_share, course: course, account_id: reader.id, role: :reader)

    %{
      conn: init_test_session(conn, %{"account_id" => writer.id}),
      owner: owner,
      writer: writer,
      reader: reader,
      course: course,
      block: block,
      foreign: foreign,
      share: share
    }
  end

  test "course writer edits the owner's template and sees the scope notice", ctx do
    {:ok, view, _} =
      live(ctx.conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.block.id}/editor")

    assert has_element?(view, "input[name='library_block[title]']")
    assert has_element?(view, "#library-inherited-edit-notice")

    render_hook(view, "update_meta", %{
      "library_block" => %{"title" => "Edited through course"},
      "tags_string" => "shared"
    })

    assert Repo.get!(LibraryBlock, ctx.block.id).title == "Edited through course"
  end

  test "reader and third-party templates stay read-only", ctx do
    reader_conn = init_test_session(ctx.conn, %{"account_id" => ctx.reader.id})

    {:ok, reader, _} =
      live(reader_conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.block.id}/editor")

    refute has_element?(reader, "input[name='library_block[title]']")

    {:ok, foreign, _} =
      live(ctx.conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.foreign.id}/editor")

    refute has_element?(foreign, "input[name='library_block[title]']")
    render_hook(foreign, "update_meta", %{"library_block" => %{"title" => "Forbidden"}})
    assert Repo.get!(LibraryBlock, ctx.foreign.id).title == ctx.foreign.title
  end

  test "a known pinned ID and a forged course URL grant no unrelated user access", ctx do
    stranger = insert(:account, role: ctx.writer.role)
    conn = init_test_session(ctx.conn, %{"account_id" => stranger.id})
    assert {:error, _} = live(conn, ~p"/studio/library/#{ctx.block.id}/editor")

    assert {:error, _} =
             live(conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.block.id}/editor")
  end

  test "stale open editors cannot save after a course share is removed without PubSub", ctx do
    {:ok, view, _} =
      live(ctx.conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.block.id}/editor")

    Repo.delete!(ctx.share)
    render_hook(view, "update_meta", %{"library_block" => %{"title" => "Stale write"}})
    assert Repo.get!(LibraryBlock, ctx.block.id).title == ctx.block.title
  end

  test "downgrade broadcasts change an open editor to read-only", ctx do
    {:ok, view, _} =
      live(ctx.conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.block.id}/editor")

    assert {:ok, _} = Content.share_course(ctx.owner, ctx.course, ctx.writer.id, :reader)
    # Same-process signal orders the reload after the access-change broadcast.
    assert render(view)
    refute has_element?(view, "input[name='library_block[title]']")
    refute has_element?(view, "#library-inherited-edit-notice")
  end

  test "list exposes inherited edit and pin controls without management actions", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/studio/courses/#{ctx.course.id}/library")
    assert has_element?(view, "#open-editor-#{ctx.block.id}[title='Open Editor']")
    assert has_element?(view, "#open-editor-#{ctx.foreign.id}[title='View Template']")
    assert has_element?(view, "input[name='pin_#{ctx.foreign.id}']:not([disabled])")
    refute has_element?(view, "#library_blocks-#{ctx.block.id} button[phx-click='share_click']")
    refute has_element?(view, "#library_blocks-#{ctx.block.id} button[phx-click='delete_click']")

    assert has_element?(
             view,
             "#copy-block-#{ctx.foreign.id}[title='Create a copy for this course']"
           )
  end

  test "course metadata route resolves the block ID and permits inherited editing", ctx do
    {:ok, view, _} =
      live(ctx.conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.block.id}/edit")

    view
    |> form("#library-form", %{"library_block" => %{"title" => "Metadata updated"}})
    |> render_submit()

    assert Repo.get!(LibraryBlock, ctx.block.id).title == "Metadata updated"
  end

  test "copy from the course bank creates a course-owned editable question", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/studio/courses/#{ctx.course.id}/library")
    view |> element("#copy-block-#{ctx.foreign.id}") |> render_click()

    copy =
      Repo.get_by!(LibraryBlock, title: ctx.foreign.title <> " (Copy)", owner_id: ctx.owner.id)

    assert Repo.get_by(CourseLibraryBlock, course_id: ctx.course.id, library_block_id: copy.id)
    assert Content.can_edit_library_block?(ctx.writer, copy)
  end

  test "copy from the foreign template editor opens an editable course-owned copy", ctx do
    {:ok, view, _} =
      live(ctx.conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.foreign.id}/editor")

    assert has_element?(view, "#library-editor-copy", "Create a copy for this course")

    {:ok, copy_view, _} =
      view |> element("#library-editor-copy") |> render_click() |> follow_redirect(ctx.conn)

    assert has_element?(copy_view, "input[name='library_block[title]']")

    copy =
      Repo.get_by!(LibraryBlock, title: ctx.foreign.title <> " (Copy)", owner_id: ctx.owner.id)

    assert Repo.get_by(CourseLibraryBlock, course_id: ctx.course.id, library_block_id: copy.id)
  end

  test "Russian locale explains inherited editing and course copies", ctx do
    conn = init_test_session(ctx.conn, %{"locale" => "ru"})

    {:ok, view, _} =
      live(conn, ~p"/studio/courses/#{ctx.course.id}/library/#{ctx.block.id}/editor")

    assert has_element?(view, "#library-inherited-edit-notice", "отдельные права")
    assert has_element?(view, "#library-editor-copy", "Создать копию для курса")
  end
end
