# Imports a bundle produced by parse.exs into the question bank (library blocks).
#
# Runs on a live node (`mix run` in dev, `bin/web rpc` in prod), never raw SQL:
# everything goes through Athena.Content / Athena.Media, so changesets and
# permissions apply as usual. Parameters are passed as function arguments
# (a release `rpc` evaluates remotely and does not see the caller's env vars):
#
#     Code.require_file("scripts/quiz_import/import.exs")
#
#     QuizImport.Importer.list_owners()
#     QuizImport.Importer.run(bundle: "tmp/quiz_bundle/ikg-1sem", owner: "teacher_login")           # dry run
#     QuizImport.Importer.run(bundle: "tmp/quiz_bundle/ikg-1sem", owner: "teacher_login", apply: true)
#     QuizImport.Importer.run(bundle: "...", owner: "...", rollback: true, apply: true)
#
# Options:
#   :bundle   directory with questions.json and images/ (required)
#   :owner    login or UUID of the account that will own the library blocks (required);
#             must be allowed to edit the library ("library.update" or admin)
#   :apply    false (default) = validate only, write nothing; true = write
#   :rollback true = delete this bundle's blocks instead of importing them
#
# Re-running is safe: questions already imported for this owner (matched by the
# `src:<set>:<n>` tag) are skipped, images are stored under a deterministic key.

defmodule QuizImport.Importer do
  import Ecto.Query

  require Logger

  alias Athena.Content
  alias Athena.Content.LibraryBlock
  alias Athena.Identity
  alias Athena.Identity.Account
  alias Athena.Media
  alias Athena.Repo

  @doc "Prints the accounts that are allowed to own library blocks."
  def list_owners, do: quietly(&do_list_owners/0)

  defp do_list_owners do
    owners =
      from(a in Account, where: is_nil(a.deleted_at) and a.status == :active, preload: :role)
      |> Repo.all()
      |> Enum.filter(&Identity.can?(&1, "library.update"))
      |> Enum.sort_by(& &1.login)

    IO.puts("Accounts that can own library blocks (#{length(owners)}):")
    Enum.each(owners, &IO.puts("  #{&1.login}  (#{&1.role.name}, id=#{&1.id})"))
    :ok
  end

  def run(opts), do: quietly(fn -> do_run(opts) end)

  # Per-row SQL logging would drown the progress output; the level is restored afterwards.
  defp quietly(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :warning)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end

  defp do_run(opts) do
    bundle = Keyword.fetch!(opts, :bundle)
    owner_ref = Keyword.fetch!(opts, :owner)
    apply? = Keyword.get(opts, :apply, false)
    rollback? = Keyword.get(opts, :rollback, false)

    with {:ok, owner} <- fetch_owner(owner_ref),
         {:ok, data} <- read_bundle(bundle) do
      mode = if apply?, do: "APPLY", else: "DRY RUN (nothing is written; pass apply: true)"
      action = if rollback?, do: "rollback", else: "import"
      IO.puts("[#{data["set"]}] #{action} -> owner #{owner.login} (#{owner.id}); #{mode}")

      summary =
        if rollback?,
          do: rollback(owner, data, apply?),
          else: import_all(owner, data, bundle, apply?)

      IO.puts("[#{data["set"]}] done: #{inspect(Map.new(summary.counts))}")
      Enum.each(summary.errors, &IO.puts("  ERROR #{&1}"))
      if summary.errors == [], do: :ok, else: {:error, :some_failed}
    else
      {:error, reason} ->
        IO.puts("ABORTED: #{reason}")
        {:error, reason}
    end
  end

  # -- owner / bundle -------------------------------------------------------

  defp fetch_owner(ref) do
    base = from(a in Account, where: is_nil(a.deleted_at), preload: :role)

    query =
      case Ecto.UUID.cast(ref) do
        {:ok, id} -> where(base, [a], a.id == ^id)
        :error -> where(base, [a], a.login == ^ref)
      end

    case Repo.one(query) do
      nil ->
        {:error, "no account with login or id #{inspect(ref)} (see list_owners/0)"}

      %Account{status: status} when status != :active ->
        {:error, "account #{inspect(ref)} is #{status}"}

      owner ->
        if Identity.can?(owner, "library.update"),
          do: {:ok, owner},
          else: {:error, "#{owner.login} is not allowed to edit the library (library.update)"}
    end
  end

  defp read_bundle(dir) do
    path = Path.join(dir, "questions.json")

    with {:ok, json} <- File.read(path),
         {:ok, %{"set" => _, "questions" => _} = data} <- Jason.decode(json) do
      {:ok, data}
    else
      _ -> {:error, "cannot read a valid bundle at #{path}"}
    end
  end

  # -- import ---------------------------------------------------------------

  defp import_all(owner, data, bundle, apply?) do
    set = data["set"]
    done = imported_sources(owner, set)
    Process.delete(:quiz_import_images)
    total = length(data["questions"])

    {counts, errors, _} =
      data["questions"]
      |> Enum.with_index(1)
      |> Enum.reduce({[created: 0, skipped: 0, failed: 0], [], done}, fn {q, i},
                                                                         {counts, errors, done} ->
        if rem(i, 50) == 0, do: IO.puts("  ... #{i}/#{total}")
        src_tag = Enum.find(q["tags"], &String.starts_with?(&1, "src:"))

        if MapSet.member?(done, src_tag) do
          {bump(counts, :skipped), errors, done}
        else
          case import_question(owner, q, set, bundle, apply?) do
            {:ok, keys} ->
              Process.put(
                :quiz_import_images,
                MapSet.union(Process.get(:quiz_import_images, MapSet.new()), MapSet.new(keys))
              )

              {bump(counts, :created), errors, MapSet.put(done, src_tag)}

            {:error, why} ->
              {bump(counts, :failed), errors ++ ["task #{q["n"]} (#{q["code"]}): #{why}"], done}
          end
        end
      end)

    images = Process.delete(:quiz_import_images) || MapSet.new()
    verb = if apply?, do: :images_uploaded, else: :images_to_upload
    %{counts: counts ++ [{verb, MapSet.size(images)}], errors: errors}
  end

  defp import_question(owner, q, set, bundle, apply?) do
    with {:ok, content, uploaded} <- resolve_images(q["content"], owner, set, bundle, apply?),
         attrs = %{
           "title" => q["title"],
           "type" => "quiz_question",
           "content" => with_ids(content),
           "tags" => q["tags"]
         },
         :ok <- write(owner, attrs, apply?) do
      {:ok, uploaded}
    end
  end

  defp write(owner, attrs, false) do
    changeset = LibraryBlock.changeset(%LibraryBlock{owner_id: owner.id}, attrs)
    if changeset.valid?, do: :ok, else: {:error, errors(changeset)}
  end

  defp write(owner, attrs, true) do
    case Content.create_library_block(owner, attrs) do
      {:ok, _block} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> {:error, errors(changeset)}
      {:error, other} -> {:error, inspect(other)}
    end
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> inspect()
  end

  defp imported_sources(owner, set) do
    import_tag = "import:" <> set

    from(lb in LibraryBlock,
      where: lb.owner_id == ^owner.id and fragment("? = ANY(?)", ^import_tag, lb.tags),
      select: lb.tags
    )
    |> Repo.all()
    |> List.flatten()
    |> Enum.filter(&String.starts_with?(&1, "src:"))
    |> MapSet.new()
  end

  # Option and pair ids are UUIDs required by the schema.
  defp with_ids(%{"options" => options} = content) when is_list(options),
    do: %{content | "options" => Enum.map(options, &Map.put(&1, "id", Ecto.UUID.generate()))}

  defp with_ids(%{"pairs" => pairs} = content) when is_list(pairs),
    do: %{content | "pairs" => Enum.map(pairs, &Map.put(&1, "id", Ecto.UUID.generate()))}

  defp with_ids(content), do: content

  # -- images ---------------------------------------------------------------

  # Swaps every `@img:<file>` placeholder for the real `/media/<key>` URL,
  # uploading the file first when it is not stored yet (apply mode only).
  defp resolve_images(content, owner, set, bundle, apply?) do
    {content, {keys, error}} =
      walk(content, {[], nil}, fn
        %{"type" => "image", "attrs" => %{"src" => "@img:" <> name} = attrs} = node, {n, nil} ->
          case ensure_image(owner, set, bundle, name, apply?) do
            {:ok, src, fresh?} ->
              {%{node | "attrs" => %{attrs | "src" => src}},
               {if(fresh?, do: [src | n], else: n), nil}}

            {:error, why} ->
              {node, {n, why}}
          end

        node, acc ->
          {node, acc}
      end)

    if error, do: {:error, error}, else: {:ok, content, keys}
  end

  defp ensure_image(owner, set, bundle, name, apply?) do
    key = "library/#{owner.id}/quiz-import/#{set}/#{name}"
    src = "/media/" <> key

    cond do
      Media.get_file_by_key(key) != nil ->
        {:ok, src, false}

      not apply? ->
        {:ok, src, true}

      true ->
        upload_image(owner, bundle, name, key, src)
    end
  end

  defp upload_image(owner, bundle, name, key, src) do
    bucket = Application.get_env(:athena, Athena.Media)[:bucket] || "athena"

    with {:ok, bin} <- File.read(Path.join([bundle, "images", name])),
         {:ok, _} <-
           bucket |> ExAws.S3.put_object(key, bin, content_type: "image/png") |> ExAws.request(),
         {:ok, _file} <-
           Media.create_file(%{
             "bucket" => bucket,
             "key" => key,
             "original_name" => name,
             "mime_type" => "image/png",
             "size" => byte_size(bin),
             "context" => "course_material",
             "owner_id" => owner.id
           }) do
      {:ok, src, true}
    else
      error -> {:error, "image #{name}: #{String.slice(inspect(error), 0, 300)}"}
    end
  end

  # Depth-first rewrite of a JSON-like structure, threading an accumulator.
  defp walk(%{} = map, acc, fun) do
    {map, acc} = fun.(map, acc)

    Enum.reduce(map, {%{}, acc}, fn {k, v}, {out, acc} ->
      {v, acc} = walk(v, acc, fun)
      {Map.put(out, k, v), acc}
    end)
  end

  defp walk(list, acc, fun) when is_list(list) do
    {items, acc} =
      Enum.reduce(list, {[], acc}, fn item, {out, acc} ->
        {item, acc} = walk(item, acc, fun)
        {[item | out], acc}
      end)

    {Enum.reverse(items), acc}
  end

  defp walk(other, acc, _fun), do: {other, acc}

  # -- rollback -------------------------------------------------------------

  defp rollback(owner, data, apply?) do
    import_tag = "import:" <> data["set"]

    blocks =
      from(lb in LibraryBlock,
        where: lb.owner_id == ^owner.id and fragment("? = ANY(?)", ^import_tag, lb.tags)
      )
      |> Repo.all()

    Enum.reduce(blocks, %{counts: [deleted: 0, failed: 0], errors: []}, fn block, acc ->
      with true <- apply?,
           {:error, why} <- Content.delete_library_block(owner, block) do
        acc = update_in(acc.counts, &bump(&1, :failed))
        %{acc | errors: acc.errors ++ ["#{block.title}: #{inspect(why)}"]}
      else
        _ -> update_in(acc.counts, &bump(&1, :deleted))
      end
    end)
  end

  defp bump(counts, key, by \\ 1), do: Keyword.update!(counts, key, &(&1 + by))
end
