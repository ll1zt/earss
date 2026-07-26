#!/usr/bin/env sh
# Container entrypoint: migrate then start the Mix release.
set -eu

export RELEASE_TMP="${RELEASE_TMP:-/tmp/earss}"
mkdir -p "$RELEASE_TMP"

echo "[earss] running migrations…"
/app/bin/earss eval "Earss.Release.migrate()"

echo "[earss] starting (PORT=${PORT:-4000})…"
exec /app/bin/earss start
