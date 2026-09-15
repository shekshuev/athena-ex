defmodule Athena.Content.Workers.CourseDeepCopyTest do
  use Athena.DataCase, async: true

  import Ecto.Query
  import Athena.Factory

  alias Athena.Content.{Courses, Sections, Blocks, Course, Section, Block}
  alias Athena.Content.Workers.CourseDeepCopy
  alias Athena.Media.File, as: MediaFile

  setup do
    admin =
      insert(:account,
        role: insert(:role, permissions: ["admin", "courses.read", "courses.create"])
      )

    %{admin: admin}
  end

  defp perform_copy(new_course, source_course) do
    CourseDeepCopy.perform(%Oban.Job{
      args: %{"new_course_id" => new_course.id, "source_course_id" => source_course.id}
    })
  end

  describe "perform/1" do
    test "copies nested sections preserving hierarchy, order and access rules", %{admin: admin} do
      source = insert(:course, owner_id: admin.id)

      {:ok, root} =
        Sections.create_section(admin, %{
          "title" => "Module 1",
          "course_id" => source.id,
          "order" => 0,
          "access_rules" => %{"reset_waterline" => true}
        })

      {:ok, _child} =
        Sections.create_section(admin, %{
          "title" => "Lesson 1.1",
          "course_id" => source.id,
          "parent_id" => root.id,
          "order" => 1
        })

      {:ok, new_course} = Courses.duplicate_course(admin, source.id, "Databases v2")

      assert :ok = perform_copy(new_course, source)

      new_sections =
        Section |> where([s], s.course_id == ^new_course.id) |> Repo.all()

      assert length(new_sections) == 2

      new_root = Enum.find(new_sections, &(&1.title == "Module 1"))
      new_child = Enum.find(new_sections, &(&1.title == "Lesson 1.1"))

      assert new_root.id != root.id
      assert is_nil(new_root.parent_id)
      assert new_child.parent_id == new_root.id
      assert new_child.path.labels == new_root.path.labels ++ [List.last(new_child.path.labels)]
      assert new_root.access_rules.reset_waterline == true

      # source untouched
      assert Repo.get!(Section, root.id).course_id == source.id
    end

    test "copies blocks with content, order, embeds and correct section linkage", %{
      admin: admin
    } do
      source = insert(:course, owner_id: admin.id)

      {:ok, section} =
        Sections.create_section(admin, %{"title" => "Intro", "course_id" => source.id})

      {:ok, _block} =
        Blocks.create_block(admin, %{
          "type" => "text",
          "content" => %{"text" => "hello world"},
          "section_id" => section.id,
          "order" => 1024
        })

      {:ok, new_course} = Courses.duplicate_course(admin, source.id, "Copy With Blocks")
      assert :ok = perform_copy(new_course, source)

      [new_section] = Section |> where([s], s.course_id == ^new_course.id) |> Repo.all()
      [new_block] = Block |> where([b], b.section_id == ^new_section.id) |> Repo.all()

      assert new_block.type == :text
      assert new_block.content == %{"text" => "hello world"}
      assert new_block.order == 1024

      # source block untouched, still points at the original section
      original_blocks = Blocks.list_blocks_by_section(section.id)
      assert length(original_blocks) == 1
    end

    test "sets copy_status to :ready and does not affect the source course", %{admin: admin} do
      source = insert(:course, owner_id: admin.id, title: "Original Title")
      {:ok, new_course} = Courses.duplicate_course(admin, source.id, "Ready Copy")

      assert new_course.copy_status == :copying
      assert :ok = perform_copy(new_course, source)

      reloaded = Repo.get!(Course, new_course.id)
      assert reloaded.copy_status == :ready

      reloaded_source = Repo.get!(Course, source.id)
      assert reloaded_source.title == "Original Title"
    end

    test "discards the job if the draft course row no longer exists", %{admin: admin} do
      source = insert(:course, owner_id: admin.id)

      assert :discard =
               CourseDeepCopy.perform(%Oban.Job{
                 args: %{"new_course_id" => Ecto.UUID.generate(), "source_course_id" => source.id}
               })
    end

    @tag :external
    test "sets copy_status to :failed and returns an error if an S3 copy fails", %{admin: admin} do
      source = insert(:course, owner_id: admin.id)

      {:ok, section} =
        Sections.create_section(admin, %{"title" => "Broken Media", "course_id" => source.id})

      broken_file =
        insert(:media_file,
          bucket: "definitely-not-a-real-bucket",
          key: "courses/#{source.id}/broken.png",
          context: :course_material,
          original_name: "broken.png"
        )

      {:ok, _block} =
        Blocks.create_block(admin, %{
          "type" => "image",
          "content" => %{"url" => "/media/#{broken_file.key}"},
          "section_id" => section.id
        })

      {:ok, new_course} = Courses.duplicate_course(admin, source.id, "Copy That Fails")

      assert {:error, _reason} = perform_copy(new_course, source)

      assert Repo.get!(Course, new_course.id).copy_status == :failed
    end

    @tag :external
    test "copies referenced S3 media and rewrites URLs in the copied block's content", %{
      admin: admin
    } do
      source = insert(:course, owner_id: admin.id)

      {:ok, section} =
        Sections.create_section(admin, %{"title" => "With Media", "course_id" => source.id})

      file =
        insert(:media_file,
          key: "courses/#{source.id}/original.png",
          context: :course_material,
          original_name: "original.png"
        )

      ExAws.S3.put_object(file.bucket, file.key, "fake image bytes") |> ExAws.request!()

      on_exit(fn -> ExAws.S3.delete_object(file.bucket, file.key) |> ExAws.request() end)

      {:ok, block} =
        Blocks.create_block(admin, %{
          "type" => "image",
          "content" => %{"url" => "/media/#{file.key}"},
          "section_id" => section.id
        })

      {:ok, new_course} = Courses.duplicate_course(admin, source.id, "Copy With Media")
      assert :ok = perform_copy(new_course, source)

      [new_section] = Section |> where([s], s.course_id == ^new_course.id) |> Repo.all()
      [new_block] = Block |> where([b], b.section_id == ^new_section.id) |> Repo.all()

      new_url = new_block.content["url"]
      refute new_url == block.content["url"]
      assert new_url =~ "courses/#{new_course.id}/"

      new_key = String.replace_prefix(new_url, "/media/", "")
      new_file = Repo.get_by(MediaFile, key: new_key)
      assert new_file != nil
      assert new_file.original_name == "original.png"

      assert {:ok, _} = ExAws.S3.head_object(new_file.bucket, new_file.key) |> ExAws.request()

      on_exit(fn -> ExAws.S3.delete_object(new_file.bucket, new_file.key) |> ExAws.request() end)
    end

    @tag :external
    test "does not copy media files that are not referenced by any block", %{admin: admin} do
      source = insert(:course, owner_id: admin.id)

      {:ok, _section} =
        Sections.create_section(admin, %{"title" => "Empty", "course_id" => source.id})

      unreferenced =
        insert(:media_file,
          key: "courses/#{source.id}/unused.png",
          context: :course_material,
          original_name: "unused.png"
        )

      {:ok, new_course} = Courses.duplicate_course(admin, source.id, "Copy No Media")
      assert :ok = perform_copy(new_course, source)

      copied_count =
        MediaFile
        |> where([f], like(f.key, ^"courses/#{new_course.id}/%"))
        |> Repo.aggregate(:count)

      assert copied_count == 0
      assert Repo.get(MediaFile, unreferenced.id) != nil
    end

    @tag :external
    test "retrying after a partial failure cleans up and re-copies without duplicates", %{
      admin: admin
    } do
      source = insert(:course, owner_id: admin.id)

      {:ok, section} =
        Sections.create_section(admin, %{"title" => "Retry Me", "course_id" => source.id})

      {:ok, _block} =
        Blocks.create_block(admin, %{
          "type" => "text",
          "content" => %{"text" => "v1"},
          "section_id" => section.id
        })

      {:ok, new_course} = Courses.duplicate_course(admin, source.id, "Retry Copy")

      assert :ok = perform_copy(new_course, source)
      assert :ok = perform_copy(new_course, source)

      new_sections = Section |> where([s], s.course_id == ^new_course.id) |> Repo.all()
      assert length(new_sections) == 1

      [new_section] = new_sections
      new_blocks = Block |> where([b], b.section_id == ^new_section.id) |> Repo.all()
      assert length(new_blocks) == 1
    end
  end
end
