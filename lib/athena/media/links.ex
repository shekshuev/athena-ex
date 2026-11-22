defmodule Athena.Media.Links do
  @moduledoc "Read-only audit of saved direct storage URLs that would bypass /media authorization."

  alias Athena.Media.Storage

  def scan(fetch, cursor \\ nil, found \\ []) do
    rows = fetch.(cursor)

    matches =
      Enum.flat_map(rows, fn {id, content} ->
        case direct_urls(content) do
          [] -> []
          urls -> [%{id: id, direct_links: length(urls)}]
        end
      end)

    case List.last(rows) do
      nil -> Enum.reverse(found)
      {id, _} -> scan(fetch, id, Enum.reverse(matches, found))
    end
  end

  def direct_urls(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&direct_urls/1) |> Enum.uniq()

  def direct_urls(value) when is_list(value),
    do: value |> Enum.flat_map(&direct_urls/1) |> Enum.uniq()

  def direct_urls(value) when is_binary(value) do
    Regex.scan(~r{https?://[^\s<>"']+}, value)
    |> List.flatten()
    |> Enum.filter(&storage_url?/1)
    |> Enum.uniq()
  end

  def direct_urls(_), do: []

  defp storage_url?(url) do
    uri = URI.parse(url)
    config = Application.get_env(:athena, Athena.Media, [])
    internal = ExAws.Config.new(:s3)
    hosts = [config[:public_host], internal.host] |> Enum.reject(&is_nil/1)

    uri.host in hosts and is_binary(uri.path) and
      Enum.any?(Storage.buckets(), &String.starts_with?(uri.path, "/#{&1}/"))
  end
end
