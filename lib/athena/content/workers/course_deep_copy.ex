defmodule Athena.Content.Workers.CourseDeepCopy do
  @moduledoc """
  Deep-copies a course's sections, blocks, and referenced S3 media into an
  already-created draft course (see `Athena.Content.Courses.duplicate_course/3`).

  This exists so a teacher can evolve a course (e.g. add new
  waterline-blocking tasks) for future cohorts without affecting cohorts
  already enrolled in — and who may have already completed — the original:
  the source course's sections/blocks are read-only here and never modified,
  and cohorts keep pointing at whichever `course_id` their `enrollment` was
  created against.

  Retries are idempotent: any sections/blocks/media left over from a failed
  previous attempt at the same `new_course_id` are torn down before copying
  starts again.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  import Ecto.Query

  alias Athena.Repo
  alias Athena.Content.{Course, Section, Block, Blocks}
  alias Athena.Media
  alias Athena.Media.File, as: MediaFile

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"new_course_id" => new_course_id, "source_course_id" => source_course_id}
      }) do
    case Repo.get(Course, new_course_id) do
      nil ->
        Logger.warning("[Content.CourseDeepCopy] Course #{new_course_id} no longer exists")
        :discard

      new_course ->
        cleanup_partial_copy(new_course_id)

        case copy_course(source_course_id, new_course_id) do
          :ok ->
            finish(new_course, :ready)
            :ok

          {:error, reason} ->
            Logger.error(
              "[Content.CourseDeepCopy] Copy #{source_course_id} -> #{new_course_id} failed: #{inspect(reason)}"
            )

            finish(new_course, :failed)
            {:error, reason}
        end
    end
  end

  @doc false
  defp finish(course, status) do
    course
    |> Ecto.Changeset.change(copy_status: status)
    |> Repo.update!()

    Phoenix.PubSub.broadcast(Athena.PubSub, "user_courses:#{course.owner_id}", :refresh_courses)
  end

  @doc false
  defp cleanup_partial_copy(new_course_id) do
    Repo.delete_all(from s in Section, where: s.course_id == ^new_course_id)

    MediaFile
    |> where([f], like(f.key, ^"courses/#{new_course_id}/%"))
    |> Repo.all()
    |> Enum.each(&Media.delete_file/1)
  end

  @doc false
  defp copy_course(source_course_id, new_course_id) do
    with {:ok, section_id_map} <- copy_sections(source_course_id, new_course_id) do
      copy_blocks(source_course_id, new_course_id, section_id_map)
    end
  end

  @doc false
  defp copy_sections(source_course_id, new_course_id) do
    sections =
      Section
      |> where([s], s.course_id == ^source_course_id)
      |> order_by([s], asc: s.order, asc: s.inserted_at)
      |> Repo.all()

    id_map = Map.new(sections, &{&1.id, Ecto.UUID.generate()})
    sorted_by_depth = Enum.sort_by(sections, &length(&1.path.labels))

    Repo.transaction(fn ->
      result =
        Enum.reduce_while(sorted_by_depth, %{}, fn section, new_paths ->
          insert_copied_section(section, new_course_id, id_map, new_paths)
        end)

      case result do
        {:error, reason} -> Repo.rollback(reason)
        _new_paths -> id_map
      end
    end)
  end

  @doc false
  defp insert_copied_section(section, new_course_id, id_map, new_paths) do
    new_id = Map.fetch!(id_map, section.id)
    new_parent_id = section.parent_id && Map.fetch!(id_map, section.parent_id)
    parent_path = section.parent_id && Map.fetch!(new_paths, section.parent_id)
    new_path_string = Section.build_path(new_id, parent_path)

    new_section = %Section{
      id: new_id,
      title: section.title,
      order: section.order,
      path: %EctoLtree.LabelTree{labels: String.split(new_path_string, ".")},
      visibility: section.visibility,
      access_rules: section.access_rules,
      engagement_rule: section.engagement_rule,
      course_id: new_course_id,
      parent_id: new_parent_id
    }

    case Repo.insert(new_section) do
      {:ok, _} -> {:cont, Map.put(new_paths, section.id, new_path_string)}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @doc false
  defp copy_blocks(source_course_id, new_course_id, section_id_map) do
    blocks = Blocks.list_blocks_by_section_ids(Map.keys(section_id_map))

    with {:ok, key_replacements} <-
           copy_referenced_media(source_course_id, new_course_id, blocks) do
      Repo.transaction(fn ->
        Enum.each(blocks, fn block ->
          insert_copied_block(block, section_id_map, key_replacements)
        end)
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  defp insert_copied_block(block, section_id_map, key_replacements) do
    new_block = %Block{
      id: Ecto.UUID.generate(),
      type: block.type,
      content: rewrite_content(block.content, key_replacements),
      order: block.order,
      visibility: block.visibility,
      access_rules: block.access_rules,
      completion_rule: block.completion_rule,
      engagement_rule: block.engagement_rule,
      section_id: Map.fetch!(section_id_map, block.section_id)
    }

    case Repo.insert(new_block) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Copies only the media files actually referenced by the given (source)
  # blocks' `content` — matching `Athena.Workers.MediaCleanup`'s substring
  # technique for finding references, but to select what to copy rather
  # than what to delete. Returns a map of `old_url => new_url` to rewrite
  # into the copied blocks' content.
  defp copy_referenced_media(source_course_id, new_course_id, blocks) do
    encoded_contents = Enum.map(blocks, &Jason.encode!(&1.content))

    referenced_files =
      MediaFile
      |> where([f], like(f.key, ^"courses/#{source_course_id}/%"))
      |> Repo.all()
      |> Enum.filter(fn file ->
        Enum.any?(encoded_contents, &String.contains?(&1, file.key))
      end)

    Enum.reduce_while(referenced_files, {:ok, %{}}, fn file, {:ok, replacements} ->
      case copy_single_file(file, new_course_id) do
        {:ok, new_key} ->
          {:cont, {:ok, Map.put(replacements, "/media/#{file.key}", "/media/#{new_key}")}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  defp copy_single_file(file, new_course_id) do
    new_key = "courses/#{new_course_id}/#{Ecto.UUID.generate()}-#{file.original_name}"

    with {:ok, _} <-
           ExAws.S3.put_object_copy(file.bucket, new_key, file.bucket, file.key)
           |> ExAws.request(),
         {:ok, _new_file} <-
           Media.create_file(%{
             "bucket" => file.bucket,
             "key" => new_key,
             "original_name" => file.original_name,
             "mime_type" => file.mime_type,
             "size" => file.size,
             "context" => "course_material",
             "owner_id" => file.owner_id
           }) do
      {:ok, new_key}
    end
  end

  @doc false
  defp rewrite_content(content, replacements) when is_map(content) do
    Map.new(content, fn {k, v} -> {k, rewrite_content(v, replacements)} end)
  end

  defp rewrite_content(content, replacements) when is_list(content) do
    Enum.map(content, &rewrite_content(&1, replacements))
  end

  defp rewrite_content(content, replacements) when is_binary(content) do
    Enum.reduce(replacements, content, fn {old_url, new_url}, acc ->
      String.replace(acc, old_url, new_url)
    end)
  end

  defp rewrite_content(content, _replacements), do: content
end
