#!/usr/bin/env bash
# Pulls the athena-ex web + runner images from GHCR, packs them into
# tarballs, ships them to a server with no outbound internet access over
# SSH (password auth), loads them there, and restarts only the app
# containers (athena_web, athena_runner_db/compiled/script, athena_runner_pg).
# postgres/minio/minio-init are never touched — they hold production data
# and don't need to change on an app redeploy.
#
# Usage:
#   ./scripts/deploy.sh <ssh_host> <ssh_user> <ssh_password> \
#     [--version vX.Y.Z] [--image-os u22|u24]
#
#   --version    image tag before the -<image_os> suffix, e.g. "v0.17.0"
#                (default: latest)
#   --image-os   u22 or u24, must match the target host's IMAGE_OS in .env
#                (default: u22)
#
# Requires locally: docker, sshpass, ssh, scp.
# Requires on the server: docker, docker compose, a ~/athena directory with
# docker-compose.prod.yml + .env already in place (see README.md).
set -euo pipefail

usage() {
  echo "Usage: $0 <ssh_host> <ssh_user> <ssh_password> [--version vX.Y.Z] [--image-os u22|u24]" >&2
  exit 1
}

if [[ $# -lt 3 ]]; then
  usage
fi

SSH_HOST=$1
SSH_USER=$2
SSH_PASSWORD=$3
shift 3

VERSION="latest"
IMAGE_OS="u22"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION=$2
      shift 2
      ;;
    --image-os)
      IMAGE_OS=$2
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ "$IMAGE_OS" != "u22" && "$IMAGE_OS" != "u24" ]]; then
  echo "--image-os must be u22 or u24, got: $IMAGE_OS" >&2
  exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
  echo "sshpass is required (password-based non-interactive ssh/scp). Install it and re-run." >&2
  echo "Note: key-based auth would be safer than passing a password on the command line —" >&2
  echo "consider switching once this is working." >&2
  exit 1
fi

GHCR_OWNER="shekshuev"
REMOTE_DIR="athena"
VARIANTS=(web runner-db runner-compiled runner-script)
# Only these get stopped/recreated. postgres, minio, minio-init are
# deliberately excluded — they're not part of this list.
APP_SERVICES=(athena_web athena_runner_db athena_runner_compiled athena_runner_script athena_runner_pg)

TAG="${VERSION}-${IMAGE_OS}"
LATEST_TAG="latest-${IMAGE_OS}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

export SSHPASS="$SSH_PASSWORD"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=no)
ssh() { sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$@"; }
scp() { sshpass -e scp "${SSH_OPTS[@]}" "$@"; }

echo "==> Pulling images (tag: ${TAG})"
for variant in "${VARIANTS[@]}"; do
  docker pull "ghcr.io/${GHCR_OWNER}/athena-ex-${variant}:${TAG}"
done

echo "==> Saving images to ${WORKDIR}"
for variant in "${VARIANTS[@]}"; do
  docker save "ghcr.io/${GHCR_OWNER}/athena-ex-${variant}:${TAG}" \
    | gzip > "${WORKDIR}/athena-ex-${variant}-${TAG}.tar.gz"
done

echo "==> Copying tarballs to ${SSH_USER}@${SSH_HOST}:~/${REMOTE_DIR}/"
scp "${WORKDIR}"/*.tar.gz "${SSH_USER}@${SSH_HOST}:~/${REMOTE_DIR}/"

echo "==> Loading images and restarting app services on the server"
ssh bash -s <<EOF
set -euo pipefail
cd ~/${REMOTE_DIR}

for f in athena-ex-*-${TAG}.tar.gz; do
  echo "Loading \$f"
  gunzip -c "\$f" | docker load
  rm -f "\$f"
done

for variant in ${VARIANTS[@]}; do
  docker tag "ghcr.io/${GHCR_OWNER}/athena-ex-\${variant}:${TAG}" \
             "ghcr.io/${GHCR_OWNER}/athena-ex-\${variant}:${LATEST_TAG}"
done

docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate \
  ${APP_SERVICES[@]}

echo "---"
docker compose -f docker-compose.prod.yml ps ${APP_SERVICES[@]}
EOF

echo "==> Done. Tailing athena_web logs (Ctrl+C to stop watching, containers keep running):"
ssh "docker logs -f --tail 50 athena_web"
