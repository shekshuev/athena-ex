-- Read-only diagnostics for the production database.
--
-- Run inside the Postgres container:
--   docker exec -i athena_prod_postgres \
--     psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -x < scripts/db_diagnostics.sql
--
-- pg_stat_statements needs `shared_preload_libraries=pg_stat_statements`
-- (docker-compose.prod.yml) and the extension (migration
-- enable_pg_stat_statements). Reset the counters after a deploy with
--   SELECT pg_stat_statements_reset();
-- so the numbers describe the new code only.

\echo '== Top 25 statements by total execution time =='
SELECT round(total_exec_time::numeric / 1000, 1) AS total_s,
       calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows,
       round(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct,
       left(regexp_replace(query, '\s+', ' ', 'g'), 300) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 25;

\echo '== Top 15 statements by calls =='
SELECT calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 200) AS query
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 15;

\echo '== Table sizes (table + indexes + toast) =='
SELECT relname AS table_name,
       pg_size_pretty(pg_total_relation_size(relid)) AS total,
       pg_size_pretty(pg_relation_size(relid)) AS heap,
       pg_size_pretty(pg_indexes_size(relid)) AS indexes,
       n_live_tup,
       n_dead_tup,
       seq_scan,
       idx_scan,
       last_autovacuum,
       last_autoanalyze
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 30;

\echo '== Tables read mostly by sequential scans =='
SELECT relname, seq_scan, seq_tup_read, idx_scan,
       round(seq_tup_read::numeric / nullif(seq_scan, 0)) AS avg_rows_per_seq_scan
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY seq_tup_read DESC
LIMIT 20;

\echo '== Indexes never used since the last stats reset (candidates to drop) =='
SELECT s.relname AS table_name,
       s.indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
       s.idx_scan
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
  AND NOT i.indisunique
  AND NOT i.indisprimary
ORDER BY pg_relation_size(s.indexrelid) DESC;

\echo '== engagement_events volume =='
SELECT count(*) AS rows,
       min(inserted_at) AS first_event,
       max(inserted_at) AS last_event,
       pg_size_pretty(pg_total_relation_size('engagement_events')) AS total_size
FROM engagement_events;

SELECT date_trunc('day', inserted_at) AS day, count(*) AS events
FROM engagement_events
WHERE inserted_at > now() - interval '14 days'
GROUP BY 1
ORDER BY 1;

SELECT event_type, count(*) AS events
FROM engagement_events
WHERE inserted_at > now() - interval '7 days'
GROUP BY 1
ORDER BY 2 DESC;

\echo '== Account unblocking =='
SELECT id, login, status, failed_login_attempts, last_failed_at
FROM accounts
WHERE status = 'temporary_blocked'
ORDER BY last_failed_at NULLS FIRST;

SELECT state, count(*), min(scheduled_at), max(scheduled_at)
FROM oban_jobs
WHERE worker = 'Athena.Workers.UnblockAccount'
GROUP BY state;

\echo '== Oban jobs by worker and state =='
SELECT worker, state, count(*)
FROM oban_jobs
GROUP BY worker, state
ORDER BY worker, state;
