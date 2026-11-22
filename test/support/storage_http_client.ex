defmodule Athena.StorageHttpClient do
  @moduledoc false
  @behaviour ExAws.Request.HttpClient

  def request(method, url, _body, _headers, _opts) do
    state = Process.get(:storage_http_state)
    uri = URI.parse(url)
    policy? = Map.has_key?(URI.decode_query(uri.query || ""), "policy")
    bucket = String.trim(uri.path, "/")
    Process.put(:storage_http_calls, [{method, uri.query} | Process.get(:storage_http_calls, [])])

    cond do
      state[:deny] ->
        response(403, "<Error><Code>AccessDenied</Code></Error>")

      method == :head and not Map.has_key?(state.buckets, bucket) ->
        response(404, "<Error><Code>NoSuchBucket</Code></Error>")

      method == :head ->
        response(200, "")

      method == :put ->
        Process.put(:storage_http_state, put_in(state, [:buckets, bucket], nil))
        response(200, "")

      method == :delete and policy? ->
        Process.put(:storage_http_state, put_in(state, [:buckets, bucket], nil))
        response(204, "")

      method == :get and is_nil(state.buckets[bucket]) ->
        response(404, "<Error><Code>NoSuchBucketPolicy</Code></Error>")

      method == :get ->
        response(200, state.buckets[bucket])
    end
  end

  defp response(status, body), do: {:ok, %{status_code: status, headers: [], body: body}}
end
