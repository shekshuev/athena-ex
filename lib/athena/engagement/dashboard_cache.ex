defmodule Athena.Engagement.DashboardCache do
  @moduledoc """
  A short-lived cache in front of the course-wide dashboard aggregates
  (`Athena.Engagement.Metrics.student_radar/3` and friends), so switching
  tabs or reloading doesn't recompute the same cohort × course × window
  again. Entries live `dashboard_cache_ttl_ms` (default one minute) -
  short enough that today's activity still shows up almost immediately;
  `0` turns the cache off (the test suite does).
  """

  @cache :engagement_dashboard_cache

  @doc false
  def child_spec(_opts),
    do: Supervisor.child_spec({Cachex, name: @cache}, id: @cache)

  @doc "Returns the cached value for `key`, computing and storing it on a miss."
  @spec fetch(term(), (-> term())) :: term()
  def fetch(key, fun) do
    case ttl() do
      0 ->
        fun.()

      # `Cachex.fetch/3` runs `fun` once per key even when several
      # requests miss at the same moment (teachers opening the same course
      # dashboard together); the others wait for that one result.
      ttl ->
        cachex_fetch(key, fun, ttl)
    end
  end

  defp cachex_fetch(key, fun, ttl) do
    case Cachex.fetch(@cache, key, fn -> {:commit, fun.(), expire: ttl} end) do
      {status, value} when status in [:ok, :commit] -> value
      _error -> fun.()
    end
  end

  @doc "Drops every cached dashboard."
  @spec clear() :: :ok
  def clear do
    Cachex.clear(@cache)
    :ok
  end

  defp ttl do
    :athena
    |> Application.get_env(Athena.Engagement, [])
    |> Keyword.get(:dashboard_cache_ttl_ms, 60_000)
  end
end
