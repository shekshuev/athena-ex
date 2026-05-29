defmodule Athena.Learning.DraftCache do
  @moduledoc """
  Manages draft submissions in Cachex for fast access and automatic expiration.
  Provides real-time synchronization for team collaboration via PubSub.
  """

  alias Phoenix.PubSub

  @cache_name :draft_cache
  @draft_ttl :timer.hours(1)

  @doc """
  Saves a draft to cache with 1-hour TTL.
  For team submissions, uses cohort_id; for individual, uses account_id.
  """
  @spec save_draft(String.t(), String.t() | nil, String.t(), map()) :: :ok | {:error, term()}
  def save_draft(account_id, cohort_id, block_id, content) do
    key = build_key(account_id, cohort_id, block_id)

    case Cachex.put(@cache_name, key, content, ttl: @draft_ttl) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Retrieves a draft from cache.
  Returns nil if not found or expired.
  """
  @spec get_draft(String.t(), String.t() | nil, String.t()) :: map() | nil
  def get_draft(account_id, cohort_id, block_id) do
    key = build_key(account_id, cohort_id, block_id)

    case Cachex.get(@cache_name, key) do
      {:ok, nil} -> nil
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  @doc """
  Removes a draft from cache.
  """
  @spec clear_draft(String.t(), String.t() | nil, String.t()) :: :ok | {:error, term()}
  def clear_draft(account_id, cohort_id, block_id) do
    key = build_key(account_id, cohort_id, block_id)

    case Cachex.del(@cache_name, key) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a draft exists in cache.
  """
  @spec draft_exists?(String.t(), String.t() | nil, String.t()) :: boolean()
  def draft_exists?(account_id, cohort_id, block_id) do
    key = build_key(account_id, cohort_id, block_id)

    case Cachex.exists?(@cache_name, key) do
      {:ok, exists} -> exists
      {:error, _} -> false
    end
  end

  @doc """
  Broadcasts a draft update to all team members via PubSub.
  Used for real-time collaborative editing.
  """
  @spec broadcast_draft_update(String.t() | nil, String.t(), map(), String.t()) :: :ok
  def broadcast_draft_update(nil, _block_id, _content, _updater_id), do: :ok

  def broadcast_draft_update(cohort_id, block_id, content, updater_id) do
    topic = "draft:#{cohort_id}:#{block_id}"

    PubSub.broadcast(
      Athena.PubSub,
      topic,
      {:draft_updated, %{block_id: block_id, content: content, updater_id: updater_id}}
    )
  end

  @doc """
  Subscribes to draft updates for a specific block.
  Used for real-time collaborative editing in teams.
  """
  @spec subscribe_to_draft_updates(String.t() | nil, String.t()) :: :ok | {:error, term()}
  def subscribe_to_draft_updates(nil, _block_id), do: :ok

  def subscribe_to_draft_updates(cohort_id, block_id) do
    topic = "draft:#{cohort_id}:#{block_id}"
    PubSub.subscribe(Athena.PubSub, topic)
  end

  @doc """
  Unsubscribes from draft updates.
  """
  @spec unsubscribe_from_draft_updates(String.t() | nil, String.t()) :: :ok
  def unsubscribe_from_draft_updates(nil, _block_id), do: :ok

  def unsubscribe_from_draft_updates(cohort_id, block_id) do
    topic = "draft:#{cohort_id}:#{block_id}"
    PubSub.unsubscribe(Athena.PubSub, topic)
  end

  @doc false
  defp build_key(account_id, nil, block_id), do: "draft:user:#{account_id}:#{block_id}"

  defp build_key(_account_id, cohort_id, block_id), do: "draft:team:#{cohort_id}:#{block_id}"
end
