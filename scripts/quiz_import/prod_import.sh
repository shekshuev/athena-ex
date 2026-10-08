#!/usr/bin/env bash
# Runs the quiz import inside the live Athena container on the prod host.
# Layout expected next to this script (built by pack.sh):
#   import.exs, bundles/<set>/{questions.json,images/}
#
#   ./prod_import.sh --list-owners
#   ./prod_import.sh --owner LOGIN --set ikg-1sem              # dry run, writes nothing
#   ./prod_import.sh --owner LOGIN --set ikg-1sem --apply      # import
#   ./prod_import.sh --owner LOGIN --set ikg-1sem --rollback --apply   # delete the imported blocks
#
# --owner is the login (or UUID) of the account that will own the questions.
# Env: ATHENA_CONTAINER (default athena_web), ATHENA_BIN (default /app/bin/web).
set -euo pipefail

CONTAINER="${ATHENA_CONTAINER:-athena_web}"
BIN="${ATHENA_BIN:-/app/bin/web}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR=/tmp/quiz_import

owner="" set="" apply=false rollback=false list=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) owner="${2:?--owner needs a value}"; shift 2 ;;
    --set) set="${2:?--set needs a value}"; shift 2 ;;
    --apply) apply=true; shift ;;
    --rollback) rollback=true; shift ;;
    --list-owners) list=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

rpc() { docker exec "$CONTAINER" "$BIN" rpc "$1"; }
# `docker cp` keeps the host uid, which the container's `nobody` cannot delete,
# so the staging dir is managed as root and made world-readable.
as_root() { docker exec -u root "$CONTAINER" "$@"; }

as_root rm -rf "$REMOTE_DIR"
as_root mkdir -p "$REMOTE_DIR/bundles"
trap 'as_root rm -rf "$REMOTE_DIR" || true' EXIT
docker cp "$HERE/import.exs" "$CONTAINER:$REMOTE_DIR/import.exs"

as_root chmod -R a+rX "$REMOTE_DIR"

if $list; then
  rpc "Code.require_file(\"$REMOTE_DIR/import.exs\"); QuizImport.Importer.list_owners()"
  exit 0
fi

# Values end up inside an Elixir string literal: keep them to a safe alphabet.
[[ "$owner" =~ ^[A-Za-z0-9_.@-]+$ ]] || { echo "--owner is required (letters, digits, _ . @ -)" >&2; exit 1; }
[[ "$set" =~ ^[a-z0-9-]+$ ]] || { echo "--set is required (e.g. ikg-1sem)" >&2; exit 1; }
[[ -f "$HERE/bundles/$set/questions.json" ]] || { echo "no bundle at $HERE/bundles/$set" >&2; exit 1; }

docker cp "$HERE/bundles/$set" "$CONTAINER:$REMOTE_DIR/bundles/$set"
as_root chmod -R a+rX "$REMOTE_DIR"

rpc "Code.require_file(\"$REMOTE_DIR/import.exs\"); QuizImport.Importer.run(bundle: \"$REMOTE_DIR/bundles/$set\", owner: \"$owner\", apply: $apply, rollback: $rollback)"
