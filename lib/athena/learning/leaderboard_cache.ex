defmodule Athena.Learning.LeaderboardCache do
  @moduledoc """
  Caches each competition's team leaderboard
  (`Athena.Learning.Submissions.get_team_leaderboard/1`), which joins every
  submission of the course.

  Every leaderboard viewer and every dashboard showing the competition
  reloads the board on each `"leaderboard:<course_id>"` broadcast, so
  without the cache one team's progress made all of them run the same query
  at the same moment. `Learning.broadcast_leaderboard_update/1` drops the
  entry before broadcasting; the first viewer then computes the new board and
  `Cachex.fetch/3` hands the same result to everyone asking meanwhile.

  Entries also expire after `ttl_ms` (default 5 s) as a safety net for
  changes that don't broadcast; `0` turns the cache off (the test suite does).
  """

  @cache :leaderboard_cache

  @doc false
  def child_spec(_opts),
    do: Supervisor.child_spec({Cachex, name: @cache}, id: @cache)

  @doc "Returns the cached board for `course_id`, computing it with `fun` on a miss."
  @spec fetch(String.t(), (-> term())) :: term()
  def fetch(course_id, fun) do
    case ttl() do
      0 ->
        fun.()

      ttl ->
        case Cachex.fetch(@cache, course_id, fn -> {:commit, fun.(), expire: ttl} end) do
          {status, value} when status in [:ok, :commit] -> value
          _error -> fun.()
        end
    end
  end

  @doc "Drops the cached board of `course_id`."
  @spec invalidate(String.t()) :: :ok
  def invalidate(course_id) do
    Cachex.del(@cache, course_id)
    :ok
  end

  defp ttl do
    :athena
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_ms, 5_000)
  end
end
